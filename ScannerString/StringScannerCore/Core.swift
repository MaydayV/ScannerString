import Foundation
import SwiftSyntax
import SwiftParser
import SwiftOperators

public struct FileHandleOutputStream: TextOutputStream {
    let fileHandle: FileHandle
    
    public init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }
    
    public mutating func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        fileHandle.write(data)
    }
}

public var stderr = FileHandleOutputStream(fileHandle: .standardError)

public struct StringLocation: Codable, Hashable {
    public let file: String
    public let line: Int
    public let column: Int
    public let content: String
    public let isLocalized: Bool
    public let processedContent: String
    
    public init(file: String, line: Int, column: Int, content: String, isLocalized: Bool, processedContent: String? = nil) {
        self.file = file
        self.line = line
        self.column = column
        self.content = content
        self.isLocalized = isLocalized
        self.processedContent = processedContent ?? content
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(file)
        hasher.combine(line)
        hasher.combine(column)
        hasher.combine(content)
        hasher.combine(isLocalized)
        hasher.combine(processedContent)
    }
    
    public static func == (lhs: StringLocation, rhs: StringLocation) -> Bool {
        return lhs.file == rhs.file &&
               lhs.line == rhs.line &&
               lhs.column == rhs.column &&
               lhs.content == rhs.content &&
               lhs.isLocalized == rhs.isLocalized &&
               lhs.processedContent == rhs.processedContent
    }
}

public class ProjectScanner {
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "result.queue", attributes: .concurrent)
    private var allStrings: [StringLocation] = []
    
    public init() {}
    
    public func scanProject(at path: String) {
        print("Scanning project at: \(path)", to: &stderr)
        
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            print("Error: Cannot enumerate directory contents", to: &stderr)
            return
        }
        
        let files = enumerator.compactMap { $0 as? URL }
            .filter { isValidFile($0) }
        
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            let file = files[index]
            do {
                try scanFile(at: file)
            } catch {
                print("Error scanning \(file.path): \(error)", to: &stderr)
            }
        }
        
        deduplicateStrings()
        
        outputResults()
    }
    
    private func deduplicateStrings() {
        var uniqueStrings: [String: StringLocation] = [:]
        
        for string in allStrings {
            if uniqueStrings[string.processedContent] == nil || 
              (!uniqueStrings[string.processedContent]!.isLocalized && string.isLocalized) {
                uniqueStrings[string.processedContent] = string
            }
        }
        
        allStrings = Array(uniqueStrings.values)
    }
    
    public func getScanResults() -> [StringLocation] {
        return allStrings.sorted {
            $0.file == $1.file ?
                ($0.line == $1.line ? $0.column < $1.column : $0.line < $1.line) :
                $0.file < $1.file
        }
    }
    
    private func isValidFile(_ url: URL) -> Bool {
        let validExtensions = ["swift", "m", "h"]
        guard validExtensions.contains(url.pathExtension) else { return false }
        
        let excludedPaths = [
            "/Pods/", "/Carthage/", "/.swiftpm/",
            "/Tests/", "/Test/", "/Specs/",
            "/DerivedData/", "/build/"
        ]
        
        let path = url.path
        return !excludedPaths.contains { path.contains($0) }
    }
    
    private func scanFile(at url: URL) throws {
        let source = try String(contentsOf: url, encoding: .utf8)
        let sourceFile = Parser.parse(source: source)
        
        let operatorTable = OperatorTable.standardOperators
        let foldedFile = try operatorTable.foldAll(sourceFile)
        
        let locationConverter = SourceLocationConverter(
            fileName: url.path,
            tree: foldedFile
        )
        
        let visitor = StringVisitor(
            filePath: url.path,
            locationConverter: locationConverter
        )
        
        visitor.walk(foldedFile)
        
        queue.async(flags: .barrier) {
            self.allStrings.append(contentsOf: visitor.strings)
        }
    }
    
    private func outputResults() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        do {
            let jsonData = try encoder.encode(getScanResults())
            
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
        } catch {
            print("JSON encoding error: \(error)", to: &stderr)
        }
    }
}

public class StringVisitor: SyntaxVisitor {
    let filePath: String
    let locationConverter: SourceLocationConverter
    public var strings: [StringLocation] = []
    
    public init(filePath: String, locationConverter: SourceLocationConverter) {
        self.filePath = filePath
        self.locationConverter = locationConverter
        super.init(viewMode: .sourceAccurate)
    }
    
    public override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let location = node.startLocation(converter: locationConverter)
        
        // 获取字符串的原始表示，包括插值参数
        let originalContent = node.description
        
        // 使用SwiftSyntax解析表达式段，将参数替换为 %@
        let segments = node.segments.map { segment -> String in
            if let stringSegment = segment.as(StringSegmentSyntax.self) {
                return stringSegment.content.text
            } else if let _ = segment.as(ExpressionSegmentSyntax.self) {
                // 这是一个插值表达式段 \(...)
                return "%@"
            }
            return ""
        }
        
        // 合并所有段
        let processedContent = segments.joined()
        
        guard !processedContent.isEmpty else { return .skipChildren }
        guard !shouldIgnoreString(processedContent) else { return .skipChildren }
        
        // 检查是否在日志上下文中，如果是则跳过
        if isInLoggerContext(node) {
            return .skipChildren
        }
        
        let isLocalized = isInLocalizationContext(node)
        
        let isPolicyText = isPrivacyPolicyOrLargeText(processedContent)
        let finalProcessedContent = isPolicyText ? "[POLICY_TEXT] \(processedContent)" : processedContent
        
        strings.append(StringLocation(
            file: filePath,
            line: location.line,
            column: location.column,
            content: originalContent,  // 保存原始表示，包括参数
            isLocalized: isLocalized,
            processedContent: finalProcessedContent  // 保存处理后的内容，参数被替换为 %@
        ))
        
        return .skipChildren
    }
    
    private func shouldIgnoreString(_ content: String) -> Bool {
        guard !content.isEmpty else { return true }
        
        let chineseRegex = try? NSRegularExpression(pattern: "[\\u4e00-\\u9fa5]", options: [])
        let hasChineseCharacters = chineseRegex?.firstMatch(in: content, options: [], range: NSRange(location: 0, length: content.utf16.count)) != nil
        
        if !hasChineseCharacters {
            return true
        }
        
        if content.hasPrefix("com.") { return true }
        
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp"]
        if imageExtensions.contains(where: { content.lowercased().hasSuffix(".\($0)") }) {
            return true
        }
        
        let specialCharacters = CharacterSet(charactersIn: "!@#$%^&*()_+-=[]{}|;:,.<>?/~`")
        if content.unicodeScalars.allSatisfy({ specialCharacters.contains($0) }) {
            return true
        }
        
        if content.unicodeScalars.allSatisfy({ $0.properties.isEmoji }) {
            return true
        }
        
        let regexPatterns = [
            #"^[\\/].*[\\/][a-z]*$"#,
            #"^[\\/].*[\\/]$"#,
            #"^[\\/].*$"#,
            #"^.*[\\/]$"#
        ]
        
        for pattern in regexPatterns {
            if content.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        
        return false
    }
    
    private func isInLocalizationContext(_ node: StringLiteralExprSyntax) -> Bool {
        if let functionCall = node.parent?.as(FunctionCallExprSyntax.self),
           let calledExpression = functionCall.calledExpression.as(DeclReferenceExprSyntax.self),
           calledExpression.baseName.text == "NSLocalizedString" {
            return true
        }
        return false
    }
    
    // 新增：检查是否为日志语句
    private func isInLoggerContext(_ node: StringLiteralExprSyntax) -> Bool {
        // 获取函数调用上下文
        if let functionCall = node.parent?.as(FunctionCallExprSyntax.self) {
            // 获取整个函数调用的文本描述
            let fullCallText = functionCall.description
            
            // 1. 检查是否明确包含日志调用模式
            if fullCallText.contains("logger.debug") || 
               fullCallText.contains("logger.info") || 
               fullCallText.contains("logger.warning") || 
               fullCallText.contains("logger.error") || 
               fullCallText.contains("logger.critical") ||
               fullCallText.contains("Logger") ||
               fullCallText.contains(".log(") {
                return true
            }
            
            // 2. 检查 self.logger 模式
            if fullCallText.contains("self.logger.") {
                return true
            }
            
            // 3. 检查是否是 logger.xxx(...) 形式的调用
            if let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self) {
                // 使用可选链安全访问 base
                if let baseExpr = memberAccess.base {
                    // 检查基础表达式是否是 logger 或类似的日志对象
                    if let baseIdentifier = baseExpr.as(DeclReferenceExprSyntax.self),
                       ["logger", "log", "Logger", "Log", "os_log"].contains(baseIdentifier.baseName.text) {
                        return true
                    }
                    
                    // 检查是否是 self.logger 形式
                    if let memberBase = baseExpr.as(MemberAccessExprSyntax.self),
                       let baseBase = memberBase.base,
                       let baseObject = baseBase.as(DeclReferenceExprSyntax.self),
                       baseObject.baseName.text == "self",
                       memberBase.declName.baseName.text == "logger" {
                        return true
                    }
                    
                    // 检查基础表达式的文本描述
                    let baseDescription = baseExpr.description.lowercased()
                    if baseDescription.contains("logger") || 
                       baseDescription.contains("log") {
                        return true
                    }
                }
                
                // 检查方法名是否与日志相关
                let logMethods = ["debug", "info", "warning", "error", "critical", "log", "verbose", "trace", "fatal"]
                let methodName = memberAccess.declName.baseName.text
                if logMethods.contains(methodName) {
                    return true
                }
            }
            
            // 检查直接调用的函数名是否与日志相关
            if let calledExpr = functionCall.calledExpression.as(DeclReferenceExprSyntax.self) {
                let logFunctions = ["print", "debugPrint", "NSLog", "os_log"]
                if logFunctions.contains(calledExpr.baseName.text) {
                    return true
                }
            }
        }
        
        // 如果在AppDelegate.swift文件中，进行额外检查
        if filePath.contains("AppDelegate.swift") {
            // 获取字符串原始内容
            let stringContent = node.description
            
            // 检查常见的日志消息内容
            let logMessages = [
                "应用启动完成", "初始化", "权限", "通知权限", "GameCenter", 
                "已授权", "未确定", "被拒绝", "受限"
            ]
            
            // 如果是AppDelegate中的这些消息，很可能是日志
            for message in logMessages {
                if stringContent.contains(message) {
                    return true
                }
            }
        }
        
        // 检查字符串所在代码行是否包含日志相关关键词
        let lineNumber = node.startLocation(converter: locationConverter).line
        let sourceText: String
        
        // 安全地访问源代码行
        let sourceLines = locationConverter.sourceLines
        if lineNumber > 0 && lineNumber <= sourceLines.count {
            sourceText = sourceLines[lineNumber - 1].lowercased()
        } else {
            sourceText = node.description.lowercased()
        }
        
        if sourceText.contains("logger") || 
           sourceText.contains(" log") || 
           sourceText.contains("debug") || 
           sourceText.contains("info") || 
           sourceText.contains("warning") || 
           sourceText.contains("error") {
            return true
        }
        
        return false
    }
    
    private func isPrivacyPolicyOrLargeText(_ content: String) -> Bool {
        let keywords = ["隐私政策", "个人信息", "收集", "使用", "保护", "权限", "同意", "条款", "协议", "数据"]
        let containsKeywords = keywords.contains { content.contains($0) }
        
        return content.count > 100 && containsKeywords
    }
    
    public override func visit(_ node: RegexLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let location = node.startLocation(converter: locationConverter)
        strings.append(StringLocation(
            file: filePath,
            line: location.line,
            column: location.column,
            content: node.regex.text,
            isLocalized: false
        ))
        return .skipChildren
    }
}

#if DEBUG
// 用于调试的测试工具类
public class ParameterProcessorTester {
    public static func testParameters() {
        // 使用SwiftSyntax解析器测试参数替换
        let testCases = [
            #""建议有效期：\(defaultDays)天""#,
            #""已开启 \(notifyType)""#,
            #""记录应用启动: 总启动 \(totalCount) 次, 连续 \(consecutiveCount) 天""#,
            #""嵌套测试: \(value(innerValue))""#,
            #""多参数测试: \(param1) and \(param2) with \(param3)""#,
            #""您有 \(expiredProducts.count) 个已过期的商品需要处理""#,
            #""商品「\(product.name)」的保修期将在\(product.days)天后到期""#,
            #""过期商品提醒：\(expiredProducts.filter { $0.isExpired }.count)""#,
            #""您有 \(array[0].value) 条新消息""#,
            // 添加格式化符号测试用例
            #""综合评分%.1f分""#,
            #""决策置信度%.0f%%""#,
            #""混合测试：评分%.1f分，\(count)个评价""#
        ]
        
        print("参数处理测试结果:")
        print("-------------------")
        
        for testCase in testCases {
            // 将字符串转换成Swift语法树
            let sourceFile = Parser.parse(source: testCase)
            
            // 创建位置转换器
            let locationConverter = SourceLocationConverter(fileName: "", tree: sourceFile)
            
            // 创建访问器
            let visitor = StringVisitor(filePath: "", locationConverter: locationConverter)
            
            // 访问语法树
            visitor.walk(sourceFile)
            
            // 如果有结果，打印出来
            if let result = visitor.strings.first {
                print("原始: \(testCase)")
                print("处理后: \"\(result.processedContent)\"")
                print("")
            }
        }
    }
    
    // 添加一个用于测试单个字符串的方法
    public static func testSingleString(_ input: String) -> String? {
        // 将字符串转换成Swift语法树
        let sourceFile = Parser.parse(source: input)
        
        // 创建位置转换器
        let locationConverter = SourceLocationConverter(fileName: "", tree: sourceFile)
        
        // 创建访问器
        let visitor = StringVisitor(filePath: "", locationConverter: locationConverter)
        
        // 访问语法树
        visitor.walk(sourceFile)
        
        // 返回处理后的内容
        return visitor.strings.first?.processedContent
    }
}
#endif 