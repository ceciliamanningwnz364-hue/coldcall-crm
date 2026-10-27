//
//  ColdCallLiquidCRM.swift
//  ColdCall Pro — Personal Cold Calling & Micro-CRM
//
//  Target: iOS 16.0+ / iOS 17.0+ (Optimized for iPhone 14 Pro — 120Hz ProMotion & Dynamic Island)
//  Architecture: Single-File Self-Contained MVVM + Async Disk Persistence (Zero UI Lag)
//

import SwiftUI
import Combine
import UIKit

// MARK: - 1. ТОЧКА ВХОДА В ПРИЛОЖЕНИЕ (@main)
@main
struct ColdCallLiquidCRMApp: App {
    @StateObject private var store = CRMStore()
    
    var body: some Scene {
        WindowGroup {
            MainContainerView()
                .environmentObject(store)
                .preferredColorScheme(.dark) // OLED оптимизация для iPhone 14 Pro
        }
    }
}

// MARK: - 2. ТАКТИЛЬНЫЙ ДВИЖОК (TAPTIC ENGINE — IPHONE 14 PRO)
/// Обеспечивает мгновенный отклик без задержек за счет предварительного прогрева генераторов
final class HapticManager {
    static let shared = HapticManager()
    
    private let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let selectionGenerator = UISelectionFeedbackGenerator()
    
    private init() {
        prepareAll()
    }
    
    func prepareAll() {
        lightGenerator.prepare()
        mediumGenerator.prepare()
        heavyGenerator.prepare()
        notificationGenerator.prepare()
        selectionGenerator.prepare()
    }
    
    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        switch style {
        case .light:
            lightGenerator.impactOccurred()
            lightGenerator.prepare()
        case .medium:
            mediumGenerator.impactOccurred()
            mediumGenerator.prepare()
        case .heavy, .rigid, .soft:
            heavyGenerator.impactOccurred()
            heavyGenerator.prepare()
        @unknown default:
            mediumGenerator.impactOccurred()
        }
    }
    
    func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notificationGenerator.notificationOccurred(type)
        notificationGenerator.prepare()
    }
    
    func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }
}

// MARK: - 3. МОДЕЛИ ДАННЫХ (CODABLE & IDENTIFIABLE)

/// Результат холодного звонка
enum CallOutcome: String, Codable, CaseIterable, Identifiable {
    case noAnswer = "Недозвон"
    case connected = "Разговор"
    case lead = "Лид 🔥"
    case callback = "Перезвон"
    case rejected = "Отказ"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .noAnswer: return "phone.down.fill"
        case .connected: return "waveform.and.mic"
        case .lead: return "flame.fill"
        case .callback: return "clock.arrow.circlepath"
        case .rejected: return "xmark.shield.fill"
        }
    }
    
    var tint: Color {
        switch self {
        case .noAnswer: return Color(red: 0.55, green: 0.60, blue: 0.72)
        case .connected: return Color(red: 0.22, green: 0.78, blue: 0.98)
        case .lead: return Color(red: 1.00, green: 0.52, blue: 0.20)
        case .callback: return Color(red: 0.72, green: 0.45, blue: 1.00)
        case .rejected: return Color(red: 0.95, green: 0.30, blue: 0.42)
        }
    }
    
    /// Считается ли этот звонок «разговорным» (дозвоном до ЛПР/секретаря с диалогом)
    var countsAsConversation: Bool {
        switch self {
        case .connected, .lead, .callback, .rejected:
            return true
        case .noAnswer:
            return false
        }
    }
}

/// Этап воронки для Лида в персональной CRM
enum LeadStage: String, Codable, CaseIterable, Identifiable {
    case new = "Новый"
    case qualified = "В работе"
    case meeting = "КП / Созвон"
    case closedWon = "Оплата 💰"
    case closedLost = "Архив"
    
    var id: String { rawValue }
    
    var color: Color {
        switch self {
        case .new: return .cyan
        case .qualified: return .blue
        case .meeting: return .purple
        case .closedWon: return .green
        case .closedLost: return .gray
        }
    }
    
    var icon: String {
        switch self {
        case .new: return "sparkles"
        case .qualified: return "bolt.horizontal.fill"
        case .meeting: return "video.fill"
        case .closedWon: return "checkmark.seal.fill"
        case .closedLost: return "archivebox.fill"
        }
    }
}

/// Единая запись звонка и карточки Лида
struct CallRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var phoneNumber: String
    var contactName: String
    var companyName: String
    var outcome: CallOutcome
    var durationSeconds: Int
    var notes: String
    
    // Поля CRM для Лидов
    var isLead: Bool
    var leadStage: LeadStage
    var dealAmount: Double
    var nextActionDate: Date?
    
    /// Форматированная длительность звонка (например, "02:14")
    var formattedDuration: String {
        let mins = durationSeconds / 60
        let secs = durationSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    /// Отображаемое имя или телефон
    var displayTitle: String {
        if !companyName.trimmingCharacters(in: .whitespaces).isEmpty {
            return companyName
        } else if !contactName.trimmingCharacters(in: .whitespaces).isEmpty {
            return contactName
        } else if !phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty {
            return phoneNumber
        } else {
            return "Быстрый набор"
        }
    }
}

/// Настройки целей на день
struct DailyGoalSettings: Codable, Equatable {
    var targetTotalCalls: Int = 120      // Цель по общему числу холодных звонков
    var targetConnectedCalls: Int = 40   // Цель по разговорным звонкам
    var targetLeads: Int = 5             // Цель по лидам за смену
}

// MARK: - 4. ХРАНИЛИЩЕ И БИЗНЕС-ЛОГИКА (CRM STORE — ASYNC I/O)
@MainActor
final class CRMStore: ObservableObject {
    @Published var calls: [CallRecord] = []
    @Published var goals: DailyGoalSettings = DailyGoalSettings()
    @Published var selectedDate: Date = Date()
    
    // Секундомер текущего звонка
    @Published var isTimerRunning: Bool = false
    @Published var activeCallSeconds: Int = 0
    private var timerCancellable: AnyCancellable?
    
    // Фоновая очередь для сохранения без фризов 120Hz интерфейса
    private let ioQueue = DispatchQueue(label: "com.coldcallpro.disk.io", qos: .utility)
    private let callsFileName = "coldcalls_crm_v1.json"
    private let goalsKey = "coldcalls_daily_goals_v1"
    
    init() {
        loadFromDisk()
    }
    
    // MARK: Вычисляемые метрики за выбранный день
    var todayCalls: [CallRecord] {
        let cal = Calendar.current
        return calls.filter { cal.isDate($0.timestamp, inSameDayAs: selectedDate) }
    }
    
    var todayTotalCount: Int {
        todayCalls.count
    }
    
    var todayConversationalCount: Int {
        todayCalls.filter { $0.outcome.countsAsConversation }.count
    }
    
    var todayLeadsCount: Int {
        todayCalls.filter { $0.isLead || $0.outcome == .lead }.count
    }
    
    var totalProgress: Double {
        guard goals.targetTotalCalls > 0 else { return 0 }
        return min(Double(todayTotalCount) / Double(goals.targetTotalCalls), 1.0)
    }
    
    var conversationalProgress: Double {
        guard goals.targetConnectedCalls > 0 else { return 0 }
        return min(Double(todayConversationalCount) / Double(goals.targetConnectedCalls), 1.0)
    }
    
    var leadsProgress: Double {
        guard goals.targetLeads > 0 else { return 0 }
        return min(Double(todayLeadsCount) / Double(goals.targetLeads), 1.0)
    }
    
    /// Все лиды в CRM (за все время)
    var allLeads: [CallRecord] {
        calls.filter { $0.isLead || $0.outcome == .lead }
    }
    
    /// Общий потенциал сделок в воронке
    var totalPipelineValue: Double {
        allLeads
            .filter { $0.leadStage != .closedLost }
            .reduce(0) { $0 + $1.dealAmount }
    }
    
    // MARK: Управление секундомером звонка
    func toggleCallTimer() {
        if isTimerRunning {
            stopCallTimer()
        } else {
            startCallTimer()
        }
    }
    
    func startCallTimer() {
        isTimerRunning = true
        HapticManager.shared.impact(.medium)
        timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.activeCallSeconds += 1
            }
    }
    
    func stopCallTimer() {
        isTimerRunning = false
        timerCancellable?.cancel()
        timerCancellable = nil
        HapticManager.shared.impact(.light)
    }
    
    func resetCallTimer() {
        stopCallTimer()
        activeCallSeconds = 0
    }
    
    // MARK: Операции со звонками и Лидами
    
    /// Мгновенный лог звонка (например, быстрый недозвон в 1 тап или полный звонок)
    func logCall(
        phone: String = "",
        name: String = "",
        company: String = "",
        outcome: CallOutcome,
        duration: Int? = nil,
        notes: String = "",
        isLead: Bool = false,
        dealAmount: Double = 0,
        leadStage: LeadStage = .new
    ) {
        let finalDuration = duration ?? (activeCallSeconds > 0 ? activeCallSeconds : (outcome == .noAnswer ? 12 : 45))
        let markAsLead = isLead || (outcome == .lead)
        
        let record = CallRecord(
            timestamp: Date(),
            phoneNumber: phone.trimmingCharacters(in: .whitespacesAndNewlines),
            contactName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            companyName: company.trimmingCharacters(in: .whitespacesAndNewlines),
            outcome: outcome,
            durationSeconds: finalDuration,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            isLead: markAsLead,
            leadStage: leadStage,
            dealAmount: dealAmount,
            nextActionDate: outcome == .callback ? Calendar.current.date(byAdding: .hour, value: 3, to: Date()) : nil
        )
        
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            calls.insert(record, at: 0)
        }
        
        // Тактильный отклик при достижении цели или добавлении лида
        if markAsLead {
            HapticManager.shared.notification(.success)
        } else if todayTotalCount == goals.targetTotalCalls || todayConversationalCount == goals.targetConnectedCalls {
            HapticManager.shared.notification(.success)
        } else {
            HapticManager.shared.impact(.medium)
        }
        
        resetCallTimer()
        saveToDiskAsync()
    }
    
    /// Обновление существующего звонка / лида (заметки, статус, сумма)
    func updateCall(_ updated: CallRecord) {
        guard let index = calls.firstIndex(where: { $0.id == updated.id }) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            calls[index] = updated
        }
        HapticManager.shared.selection()
        saveToDiskAsync()
    }
    
    /// Удаление записи
    func deleteCall(id: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            calls.removeAll { $0.id == id }
        }
        HapticManager.shared.impact(.light)
        saveToDiskAsync()
    }
    
    /// Обновление дневных целей
    func updateGoals(total: Int, connected: Int, leads: Int) {
        goals = DailyGoalSettings(
            targetTotalCalls: max(1, total),
            targetConnectedCalls: max(1, connected),
            targetLeads: max(1, leads)
        )
        HapticManager.shared.notification(.success)
        if let encoded = try? JSONEncoder().encode(goals) {
            UserDefaults.standard.set(encoded, forKey: goalsKey)
        }
    }
    
    /// Генерация CSV-отчета для экспорта в Файлы / Telegram / Excel
    func exportCSVString() -> String {
        var csv = "Дата;Время;Телефон;Контакт;Компания;Статус звонка;Длительность (сек);Лид;Этап CRM;Сумма сделки;Заметка\n"
        let dfDate = DateFormatter()
        dfDate.dateFormat = "dd.MM.yyyy"
        let dfTime = DateFormatter()
        dfTime.dateFormat = "HH:mm:ss"
        
        for c in calls {
            let cleanNotes = c.notes.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ";", with: ",")
            let row = [
                dfDate.string(from: c.timestamp),
                dfTime.string(from: c.timestamp),
                c.phoneNumber,
                c.contactName,
                c.companyName,
                c.outcome.rawValue,
                "\(c.durationSeconds)",
                c.isLead ? "ДА" : "НЕТ",
                c.isLead ? c.leadStage.rawValue : "-",
                "\(Int(c.dealAmount))",
                cleanNotes
            ].joined(separator: ";")
            csv += row + "\n"
        }
        return csv
    }
    
    // MARK: Persistence (Асинхронное чтение/запись на диск)
    private func getFileURL() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent(callsFileName)
    }
    
    private func saveToDiskAsync() {
        let snapshot = calls
        let url = getFileURL()
        ioQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: [.atomic])
            }
        }
    }
    
    private func loadFromDisk() {
        if let goalData = UserDefaults.standard.data(forKey: goalsKey),
           let savedGoals = try? JSONDecoder().decode(DailyGoalSettings.self, from: goalData) {
            self.goals = savedGoals
        }
        
        let url = getFileURL()
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([CallRecord].self, from: data) {
            self.calls = decoded
        } else {
            seedInitialDemoData()
        }
    }
    
    /// Стартовые демо-данные, чтобы интерфейс сразу выглядел наглядно (можно очистить в настройках)
    func seedInitialDemoData() {
        let now = Date()
        calls = [
            CallRecord(
                timestamp: now.addingTimeInterval(-320),
                phoneNumber: "+7 (999) 412-88-10",
                contactName: "Алексей Викторович (ЛПР)",
                companyName: "ТехноЛогистика МСК",
                outcome: .lead,
                durationSeconds: 185,
                notes: "Интересует поставка софта на 15 сотрудников. Отправил КП в WhatsApp, созвон в четверг в 14:00.",
                isLead: true,
                leadStage: .meeting,
                dealAmount: 145000,
                nextActionDate: Calendar.current.date(byAdding: .day, value: 1, to: now)
            ),
            CallRecord(
                timestamp: now.addingTimeInterval(-950),
                phoneNumber: "+7 (916) 700-34-19",
                contactName: "Марина (Секретарь -> Закуп)",
                companyName: "ООО СтройИнвест",
                outcome: .connected,
                durationSeconds: 74,
                notes: "Вышел на отдел закупок, сейчас бюджет закрыт до конца месяца, попросили набрать 1 числа.",
                isLead: true,
                leadStage: .qualified,
                dealAmount: 80000,
                nextActionDate: nil
            ),
            CallRecord(
                timestamp: now.addingTimeInterval(-1400),
                phoneNumber: "+7 (903) 551-09-22",
                contactName: "",
                companyName: "АвтоПарк Юг",
                outcome: .noAnswer,
                durationSeconds: 15,
                notes: "Гудки, никто не берет трубку",
                isLead: false,
                leadStage: .new,
                dealAmount: 0,
                nextActionDate: nil
            ),
            CallRecord(
                timestamp: now.addingTimeInterval(-2100),
                phoneNumber: "+7 (925) 884-12-05",
                contactName: "Дмитрий (Директор)",
                companyName: "Кафе Сеть Вкус",
                outcome: .callback,
                durationSeconds: 42,
                notes: "Едет за рулем, попросил перезвонить после 17:00, тема интересна.",
                isLead: true,
                leadStage: .new,
                dealAmount: 65000,
                nextActionDate: now.addingTimeInterval(7200)
            )
        ]
        saveToDiskAsync()
    }
    
    func clearAllCalls() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            calls.removeAll()
        }
        HapticManager.shared.notification(.warning)
        saveToDiskAsync()
    }
}

// MARK: - 5. ДИЗАЙН-СИСТЕМА LIQUID GLASS (МОДИФИКАТОРЫ И ФОН)

/// Живой глубокий фон с переливающимися стеклянными сферами (60/120fps GPU-accelerated)
struct LiquidGlassBackground: View {
    var body: some View {
        ZStack {
            // Глубокий OLED черный/индиго фон
            Color(red: 0.03, green: 0.04, blue: 0.08)
                .ignoresSafeArea()
            
            // Световые пятна для преломления через .ultraThinMaterial
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.16, green: 0.55, blue: 1.0).opacity(0.32),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: w * 0.75
                        )
                    )
                    .frame(width: w * 1.1, height: w * 1.1)
                    .offset(x: -w * 0.35, y: -h * 0.18)
                
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.58, green: 0.22, blue: 0.96).opacity(0.26),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: w * 0.7
                        )
                    )
                    .frame(width: w * 1.0, height: w * 1.0)
                    .offset(x: w * 0.38, y: h * 0.15)
                
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.08, green: 0.85, blue: 0.78).opacity(0.18),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 5,
                            endRadius: w * 0.65
                        )
                    )
                    .frame(width: w * 0.9, height: w * 0.9)
                    .offset(x: -w * 0.1, y: h * 0.55)
            }
            .ignoresSafeArea()
            .drawingGroup() // Рендеринг через Metal для идеальных 120Hz на iPhone 14 Pro
        }
    }
}

/// Модификатор карточки в стиле iOS Liquid Glass (блики, преломление, тонкая грань)
struct LiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 26
    var tintColor: Color = .white
    var tintOpacity: Double = 0.04
    
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tintColor.opacity(tintOpacity))
                    
                    // Верхний внутренний блик (Specular Highlight)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.14),
                                    Color.white.opacity(0.02),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.42),
                                Color.white.opacity(0.10),
                                tintColor.opacity(0.25),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.1
                    )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 10)
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 26, tint: Color = .white, opacity: Double = 0.04) -> some View {
        self.modifier(LiquidGlassModifier(cornerRadius: cornerRadius, tintColor: tint, tintOpacity: opacity))
    }
}

// MARK: - 6. ГЛАВНЫЙ КОНТЕЙНЕР С КАСТОМНЫМ СТЕКЛЯННЫМ TAB BAR
enum AppTab: String, CaseIterable {
    case dialer = "Пульт"
    case history = "Звонки"
    case leads = "Лиды CRM"
    case stats = "Цели"
    
    var icon: String {
        switch self {
        case .dialer: return "bolt.ring.closed"
        case .history: return "list.bullet.Waveform"
        case .leads: return "person.crop.rectangle.stack.fill"
        case .stats: return "chart.bar.xaxis"
        }
    }
    
    var sfSymbol: String {
        switch self {
        case .dialer: return "phone.connection.fill"
        case .history: return "clock.badge.checkmark.fill"
        case .leads: return "flame.fill"
        case .stats: return "slider.horizontal.3"
        }
    }
}

struct MainContainerView: View {
    @EnvironmentObject var store: CRMStore
    @State private var activeTab: AppTab = .dialer
    @State private var showGoalSheet: Bool = false
    @State private var selectedCallForEdit: CallRecord? = nil
    
    var body: some View {
        ZStack(alignment: .bottom) {
            LiquidGlassBackground()
            
            // Контент выбранной вкладки
            Group {
                switch activeTab {
                case .dialer:
                    CommandCenterView(
                        onOpenGoalEditor: { showGoalSheet = true },
                        onSelectCall: { selectedCallForEdit = $0 }
                    )
                case .history:
                    CallHistoryListView(onSelectCall: { selectedCallForEdit = $0 })
                case .leads:
                    LeadsCRMBoardView(onSelectLead: { selectedCallForEdit = $0 })
                case .stats:
                    AnalyticsAndSettingsView(onOpenGoalEditor: { showGoalSheet = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Плавающий Liquid Glass TabBar внизу экрана iPhone 14 Pro
            FloatingLiquidTabBar(activeTab: $activeTab, leadsCount: store.allLeads.count)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
        }
        .sheet(isPresented: $showGoalSheet) {
            GoalEditorSheet()
                .environmentObject(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedCallForEdit) { callRecord in
            CallAndLeadDetailSheet(record: callRecord)
                .environmentObject(store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct FloatingLiquidTabBar: View {
    @Binding var activeTab: AppTab
    var leadsCount: Int
    @Namespace private var tabAnimation
    
    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let isSelected = (activeTab == tab)
                Button {
                    guard activeTab != tab else { return }
                    HapticManager.shared.selection()
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
                        activeTab = tab
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.sfSymbol)
                                .font(.system(size: 16, weight: .semibold))
                            
                            if isSelected {
                                Text(tab.rawValue)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
                        .padding(.vertical, 12)
                        .padding(.horizontal, isSelected ? 16 : 14)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.20, green: 0.60, blue: 1.0).opacity(0.55),
                                                Color(red: 0.52, green: 0.25, blue: 0.98).opacity(0.55)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                                    )
                                    .matchedGeometryEffect(id: "ACTIVE_TAB_PILL", in: tabAnimation)
                            }
                        }
                        
                        // Бейдж количества лидов
                        if tab == .leads && leadsCount > 0 {
                            Text("\(leadsCount)")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange))
                                .offset(x: 4, y: -2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(7)
        .liquidGlass(cornerRadius: 34, tint: .cyan, opacity: 0.05)
    }
}

// MARK: - 7. ВКЛАДКА 1: ПУЛЬТ ХОЛОДНЫХ ЗВОНКОВ (COMMAND CENTER)
struct CommandCenterView: View {
    @EnvironmentObject var store: CRMStore
    var onOpenGoalEditor: () -> Void
    var onSelectCall: (CallRecord) -> Void
    
    // Поля быстрого ввода под текущим звонком
    @State private var phoneInput: String = ""
    @State private var nameInput: String = ""
    @State private var companyInput: String = ""
    @State private var noteInput: String = ""
    @State private var dealInput: String = ""
    @State private var markAsLeadToggle: Bool = false
    @State private var isExpandedForm: Bool = false
    @FocusState private var focusedField: Bool
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {
                // Верхний хедер с быстрой настройкой целей
                headerBar
                
                // Главный блок Liquid Glass с двойными кольцами прогресса (Всего звонков + Разговорных)
                progressHeroCard
                
                // Сверхбыстрая панель фиксации звонка в 1 тап + заметки
                quickCallLoggerCard
                
                // Последние звонки за сегодня (с быстрым доступом к заметке и переводу в Лид)
                recentCallsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .scrollDismissesKeyboard(.interactively)
    }
    
    // MARK: Верхняя панель
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .shadow(color: .green, radius: 4)
                    Text("COLD CALL PRO • 120Hz")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(.cyan)
                }
                Text("Рабочая смена")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            
            Spacer()
            
            Button {
                HapticManager.shared.impact(.light)
                onOpenGoalEditor()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.cyan)
                    Text("Цель: \(store.goals.targetTotalCalls)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .liquidGlass(cornerRadius: 20, tint: .cyan, opacity: 0.08)
            }
        }
    }
    
    // MARK: Кольца целей (Холодные звонки + Разговорные + Лиды)
    private var progressHeroCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 20) {
                // Двойное кольцо прогресса
                ZStack {
                    // Фоновое внешнее кольцо (Все звонки)
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 13)
                        .frame(width: 132, height: 132)
                    
                    // Активное внешнее кольцо (Все звонки, напр. 120)
                    Circle()
                        .trim(from: 0, to: store.totalProgress)
                        .stroke(
                            AngularGradient(
                                colors: [.cyan, .blue, .purple, .cyan],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 13, lineCap: .round)
                        )
                        .frame(width: 132, height: 132)
                        .rotationEffect(.degrees(-90))
                        .shadow(color: .cyan.opacity(0.45), radius: 8)
                    
                    // Фоновое внутреннее кольцо (Разговорные звонки)
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 10)
                        .frame(width: 96, height: 96)
                    
                    // Активное внутреннее кольцо (Разговорные звонки)
                    Circle()
                        .trim(from: 0, to: store.conversationalProgress)
                        .stroke(
                            LinearGradient(
                                colors: [Color(red: 0.1, green: 0.95, blue: 0.65), Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .frame(width: 96, height: 96)
                        .rotationEffect(.degrees(-90))
                    
                    // Центральный счетчик
                    VStack(spacing: 1) {
                        Text("\(store.todayTotalCount)")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text("из \(store.goals.targetTotalCalls)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                
                // Детальная разбивка целей справа от колец
                VStack(alignment: .leading, spacing: 11) {
                    MetricPillRow(
                        title: "Холодные (Всего)",
                        current: store.todayTotalCount,
                        target: store.goals.targetTotalCalls,
                        color: .cyan,
                        icon: "phone.fill"
                    )
                    
                    MetricPillRow(
                        title: "Разговорные (Дозвон)",
                        current: store.todayConversationalCount,
                        target: store.goals.targetConnectedCalls,
                        color: Color(red: 0.15, green: 0.92, blue: 0.65),
                        icon: "waveform.and.mic"
                    )
                    
                    MetricPillRow(
                        title: "Лиды за сегодня",
                        current: store.todayLeadsCount,
                        target: store.goals.targetLeads,
                        color: .orange,
                        icon: "flame.fill"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // Нижняя полоса конверсии и быстрого действия
            HStack {
                let convRate = store.todayTotalCount > 0
                    ? Int((Double(store.todayConversationalCount) / Double(store.todayTotalCount)) * 100)
                    : 0
                let remainTotal = max(0, store.goals.targetTotalCalls - store.todayTotalCount)
                let remainTalks = max(0, store.goals.targetConnectedCalls - store.todayConversationalCount)
                
                Label("Дозвон: \(convRate)%", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                
                Spacer()
                
                Text("Осталось: \(remainTotal) зв. / \(remainTalks) разг.")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.cyan)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .liquidGlass(cornerRadius: 28, tint: .blue, opacity: 0.06)
    }
    
    // MARK: Карточка мгновенного учета звонка, секундомера и заметок
    private var quickCallLoggerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Заголовок + живой секундомер разговора
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.cyan)
                    Text("Фиксация звонка и заметки")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                
                Spacer()
                
                // Кнопка секундомера для замера длительности разговора
                Button {
                    store.toggleCallTimer()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.isTimerRunning ? Color.red : Color.white.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(formatTimer(store.activeCallSeconds))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Image(systemName: store.isTimerRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(store.isTimerRunning ? .red : .cyan)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(store.isTimerRunning ? Color.red.opacity(0.22) : Color.white.opacity(0.08))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.8))
                    )
                }
            }
            
            // Кнопка сверхбыстрого недозвона в 1 касание (экономит часы при 120 звонках!)
            Button {
                store.logCall(
                    phone: phoneInput,
                    name: nameInput,
                    company: companyInput,
                    outcome: .noAnswer,
                    notes: noteInput.isEmpty ? "Недозвон / Автоответчик" : noteInput
                )
                clearInputs()
            } label: {
                HStack {
                    Image(systemName: "phone.arrow.up.right.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text("Быстрый Недозвон (+1 к цели без разговора)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Spacer()
                    Text("+1")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.15)))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            
            // Поле быстрой заметки под звонком
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "note.text")
                        .foregroundStyle(.cyan)
                    TextField("Заметка к звонку (о чем договорились, боли, ЛПР)...", text: $noteInput, axis: .vertical)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1...4)
                        .focused($focusedField)
                    
                    if !noteInput.isEmpty {
                        Button {
                            noteInput = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                )
                
                // Раскрывающийся блок данных клиента / Лида (Имя, Компания, Телефон, Сумма)
                DisclosureGroup(isExpanded: $isExpandedForm) {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            GlassTextField(icon: "building.2.fill", placeholder: "Компания / Ниша", text: $companyInput)
                            GlassTextField(icon: "person.fill", placeholder: "Имя ЛПР", text: $nameInput)
                        }
                        HStack(spacing: 10) {
                            GlassTextField(icon: "phone.fill", placeholder: "Телефон", text: $phoneInput, keyboard: .phonePad)
                            GlassTextField(icon: "rublesign.circle.fill", placeholder: "Чек сделки (₽)", text: $dealInput, keyboard: .numberPad)
                        }
                        
                        Toggle(isOn: $markAsLeadToggle) {
                            HStack(spacing: 6) {
                                Image(systemName: "flame.fill")
                                    .foregroundStyle(.orange)
                                Text("Сразу занести в CRM Лиды")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                        }
                        .tint(.orange)
                        .padding(.top, 2)
                    }
                    .padding(.top, 10)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.text.rectangle.fill")
                            .foregroundStyle(.cyan)
                        Text(companyInput.isEmpty && nameInput.isEmpty ? "Указать Контакт, Компанию, Телефон или Чек" : "Контакт: \(companyInput) \(nameInput)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .tint(.cyan)
            }
            
            // Кнопки результата РАЗГОВОРНОГО звонка
            VStack(alignment: .leading, spacing: 8) {
                Text("ИТОГ РАЗГОВОРА (ЗАСЧИТАЕТСЯ В РАЗГОВОРНЫЕ +1):")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.5))
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach([CallOutcome.connected, .lead, .callback, .rejected]) { outcome in
                        Button {
                            let amount = Double(dealInput.replacingOccurrences(of: ",", with: ".")) ?? 0
                            store.logCall(
                                phone: phoneInput,
                                name: nameInput,
                                company: companyInput,
                                outcome: outcome,
                                notes: noteInput,
                                isLead: markAsLeadToggle || outcome == .lead,
                                dealAmount: amount,
                                leadStage: outcome == .lead ? .qualified : .new
                            )
                            clearInputs()
                            focusedField = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: outcome.icon)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(outcome.tint)
                                
                                Text(outcome.rawValue)
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(outcome.tint.opacity(0.16))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .strokeBorder(outcome.tint.opacity(0.45), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
        .liquidGlass(cornerRadius: 28, tint: .purple, opacity: 0.05)
    }
    
    // MARK: Лента сегодняшних звонков
    private var recentCallsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Звонки за сегодня (\(store.todayCalls.count))")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                
                Spacer()
                
                Text("Нажми для заметки / Лида")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            
            if store.todayCalls.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "phone.connection")
                        .font(.system(size: 32))
                        .foregroundStyle(.cyan.opacity(0.6))
                    Text("Смена еще не началась")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Нажми любую кнопку результата выше, чтобы записать первый холодный звонок.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .padding(.horizontal, 16)
                .liquidGlass(cornerRadius: 24)
            } else {
                ForEach(store.todayCalls.prefix(15)) { call in
                    CallRowCard(call: call) {
                        onSelectCall(call)
                    } onToggleLead: {
                        var updated = call
                        updated.isLead.toggle()
                        if updated.isLead && updated.outcome == .noAnswer {
                            updated.outcome = .lead
                        }
                        store.updateCall(updated)
                    }
                }
            }
        }
    }
    
    private func clearInputs() {
        phoneInput = ""
        nameInput = ""
        companyInput = ""
        noteInput = ""
        dealInput = ""
        markAsLeadToggle = false
    }
    
    private func formatTimer(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - ВСПОМОГАТЕЛЬНЫЕ UI-КОМПОНЕНТЫ ПУЛЬТА

struct MetricPillRow: View {
    let title: String
    let current: Int
    let target: Int
    let color: Color
    let icon: String
    
    var progress: CGFloat {
        guard target > 0 else { return 0 }
        return min(CGFloat(current) / CGFloat(target), 1.0)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("\(current)/\(target)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 6)
        }
    }
}

struct GlassTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.85))
                .frame(width: 16)
            
            TextField(placeholder, text: $text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .keyboardType(keyboard)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                )
        )
    }
}

/// Карточка одного звонка в ленте с отображением заметки и быстрой отметкой Лида
struct CallRowCard: View {
    let call: CallRecord
    let onTap: () -> Void
    let onToggleLead: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    // Иконка статуса звонка
                    ZStack {
                        Circle()
                            .fill(call.outcome.tint.opacity(0.18))
                            .frame(width: 42, height: 42)
                        Image(systemName: call.outcome.icon)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(call.outcome.tint)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(call.displayTitle)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            
                            if call.isLead {
                                Text("ЛИД")
                                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.orange))
                            }
                        }
                        
                        HStack(spacing: 8) {
                            Text(call.outcome.rawValue)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(call.outcome.tint)
                            
                            Text("•")
                                .foregroundStyle(.white.opacity(0.3))
                            
                            Text(call.timestamp, style: .time)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                            
                            if call.outcome.countsAsConversation {
                                Text("• разг. \(call.formattedDuration)")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.cyan.opacity(0.8))
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Кнопка быстрого перевода в Лид прямо из списка
                    Button(action: onToggleLead) {
                        Image(systemName: call.isLead ? "flame.fill" : "flame")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(call.isLead ? .orange : .white.opacity(0.35))
                            .padding(9)
                            .background(
                                Circle()
                                    .fill(call.isLead ? Color.orange.opacity(0.2) : Color.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
                
                // Заметка под звонком
                if !call.notes.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 10))
                            .foregroundStyle(.cyan.opacity(0.75))
                            .padding(.top, 2)
                        Text(call.notes)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.24))
                    )
                }
            }
            .padding(14)
            .liquidGlass(cornerRadius: 22, tint: call.outcome.tint, opacity: 0.04)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 8. ВКЛАДКА 2: ПОЛНЫЙ ЖУРНАЛ ЗВОНКОВ И ЗАМЕТОК
struct CallHistoryListView: View {
    @EnvironmentObject var store: CRMStore
    var onSelectCall: (CallRecord) -> Void
    
    @State private var searchText: String = ""
    @State private var filterOutcome: CallOutcome? = nil
    @State private var onlyConversational: Bool = false
    
    private var filteredCalls: [CallRecord] {
        store.calls.filter { call in
            if onlyConversational && !call.outcome.countsAsConversation {
                return false
            }
            if let filterOutcome, call.outcome != filterOutcome {
                return false
            }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                let match = call.displayTitle.lowercased().contains(q)
                    || call.notes.lowercased().contains(q)
                    || call.phoneNumber.lowercased().contains(q)
                    || call.contactName.lowercased().contains(q)
                if !match { return false }
            }
            return true
        }
    }
    
    var body: some View {
        VStack(spacing: 14) {
            // Заголовок и поиск
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Журнал Звонков")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("Всего: \(filteredCalls.count)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .liquidGlass(cornerRadius: 14)
                }
                
                // Поисковая строка
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.cyan)
                    TextField("Поиск по заметкам, компании или номеру...", text: $searchText)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.white)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .padding(12)
                .liquidGlass(cornerRadius: 16)
                
                // Горизонтальные фильтры
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(
                            title: "Все (\(store.calls.count))",
                            isSelected: filterOutcome == nil && !onlyConversational,
                            color: .cyan
                        ) {
                            filterOutcome = nil
                            onlyConversational = false
                        }
                        
                        FilterChip(
                            title: "Только Разговорные",
                            isSelected: onlyConversational,
                            color: .green
                        ) {
                            onlyConversational.toggle()
                            filterOutcome = nil
                        }
                        
                        ForEach(CallOutcome.allCases) { outcome in
                            FilterChip(
                                title: outcome.rawValue,
                                isSelected: filterOutcome == outcome,
                                color: outcome.tint
                            ) {
                                onlyConversational = false
                                filterOutcome = (filterOutcome == outcome) ? nil : outcome
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            // Список звонков
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    ForEach(filteredCalls) { call in
                        CallRowCard(call: call) {
                            onSelectCall(call)
                        } onToggleLead: {
                            var updated = call
                            updated.isLead.toggle()
                            store.updateCall(updated)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 110)
            }
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button {
            HapticManager.shared.selection()
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.65))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? color.opacity(0.35) : Color.white.opacity(0.06))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(isSelected ? color : Color.white.opacity(0.15), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 9. ВКЛАДКА 3: ЛИДЫ И ПЕРСОНАЛЬНАЯ CRM (LEADS BOARD)
struct LeadsCRMBoardView: View {
    @EnvironmentObject var store: CRMStore
    var onSelectLead: (CallRecord) -> Void
    
    @State private var selectedStage: LeadStage? = nil
    @State private var showNewLeadSheet: Bool = false
    
    private var filteredLeads: [CallRecord] {
        guard let selectedStage else { return store.allLeads }
        return store.allLeads.filter { $0.leadStage == selectedStage }
    }
    
    var body: some View {
        VStack(spacing: 14) {
            // Верхняя шапка CRM с суммой воронки и кнопкой "+ Внести Лид"
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Моя CRM • Лиды")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Потенциал сделок: \(Int(store.totalPipelineValue)) ₽")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                    
                    Spacer()
                    
                    Button {
                        HapticManager.shared.impact(.medium)
                        showNewLeadSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("Внести Лид")
                        }
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [.orange, .pink],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .shadow(color: .orange.opacity(0.4), radius: 8, y: 4)
                    }
                }
                
                // Этапы воронки CRM
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(
                            title: "Все (\(store.allLeads.count))",
                            isSelected: selectedStage == nil,
                            color: .orange
                        ) {
                            selectedStage = nil
                        }
                        
                        ForEach(LeadStage.allCases) { stage in
                            let count = store.allLeads.filter { $0.leadStage == stage }.count
                            FilterChip(
                                title: "\(stage.rawValue) (\(count))",
                                isSelected: selectedStage == stage,
                                color: stage.color
                            ) {
                                selectedStage = (selectedStage == stage) ? nil : stage
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            // Карточки Лидов
            ScrollView(.vertical, showsIndicators: false) {
                if filteredLeads.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "flame.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(.orange.opacity(0.7))
                        Text("Лидов в этой стадии пока нет")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Отмечай успешные холодные звонки огоньком 🔥 или нажми «Внести Лид» сверху.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity)
                    .liquidGlass(cornerRadius: 26)
                    .padding(.horizontal, 16)
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(filteredLeads) { lead in
                            CRMLeadCard(
                                lead: lead,
                                onTap: { onSelectLead(lead) },
                                onChangeStage: { newStage in
                                    var copy = lead
                                    copy.leadStage = newStage
                                    store.updateCall(copy)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 110)
                }
            }
        }
        .sheet(isPresented: $showNewLeadSheet) {
            QuickCreateLeadSheet()
                .environmentObject(store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// Карточка Лида в персональной CRM с быстрыми действиями (Позвонить, WhatsApp, Смена этапа)
struct CRMLeadCard: View {
    let lead: CallRecord
    let onTap: () -> Void
    let onChangeStage: (LeadStage) -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: lead.leadStage.icon)
                                .foregroundStyle(lead.leadStage.color)
                            Text(lead.displayTitle)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        
                        if !lead.contactName.isEmpty && lead.displayTitle != lead.contactName {
                            Text("ЛПР: \(lead.contactName)")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        
                        if !lead.phoneNumber.isEmpty {
                            Text(lead.phoneNumber)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.cyan)
                        }
                    }
                    
                    Spacer()
                    
                    // Сумма сделки
                    if lead.dealAmount > 0 {
                        Text("\(Int(lead.dealAmount)) ₽")
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(Color.green.opacity(0.16))
                                    .overlay(Capsule().strokeBorder(Color.green.opacity(0.4), lineWidth: 1))
                            )
                    }
                }
                
                // Заметка по Лиду
                if !lead.notes.isEmpty {
                    Text(lead.notes)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.black.opacity(0.28))
                        )
                }
                
                // Нижняя панель: переключение стадии CRM + быстрый звонок / WhatsApp
                HStack {
                    Menu {
                        ForEach(LeadStage.allCases) { stage in
                            Button {
                                onChangeStage(stage)
                            } label: {
                                Label(stage.rawValue, systemImage: stage.icon)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(lead.leadStage.color)
                                .frame(width: 8, height: 8)
                            Text(lead.leadStage.rawValue)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(lead.leadStage.color.opacity(0.25))
                                .overlay(Capsule().strokeBorder(lead.leadStage.color.opacity(0.5), lineWidth: 1))
                        )
                    }
                    
                    Spacer()
                    
                    // Кнопка реального вызова с iPhone
                    if !lead.phoneNumber.isEmpty {
                        Button {
                            callNumber(lead.phoneNumber)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "phone.fill")
                                Text("Набрать")
                            }
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.green.opacity(0.3)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .liquidGlass(cornerRadius: 24, tint: lead.leadStage.color, opacity: 0.06)
        }
        .buttonStyle(.plain)
    }
    
    private func callNumber(_ rawPhone: String) {
        let digits = rawPhone.filter { "0123456789+".contains($0) }
        guard let url = URL(string: "tel://\(digits)") else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - 10. ВКЛАДКА 4: АНАЛИТИКА, ЦЕЛИ И ЭКСПОРТ БАЗЫ
struct AnalyticsAndSettingsView: View {
    @EnvironmentObject var store: CRMStore
    var onOpenGoalEditor: () -> Void
    @State private var showClearConfirmation: Bool = false
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {
                HStack {
                    Text("Цели и Аналитика")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                }
                
                // Карточка текущих дневных нормативов
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Твой план на смену", systemImage: "flag.checkered.2.crossed")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                        Spacer()
                        Button("Изменить") {
                            onOpenGoalEditor()
                        }
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.cyan.opacity(0.25)))
                    }
                    
                    HStack(spacing: 12) {
                        StatMiniBox(title: "Холодных", value: "\(store.goals.targetTotalCalls)", color: .cyan)
                        StatMiniBox(title: "Разговорных", value: "\(store.goals.targetConnectedCalls)", color: .green)
                        StatMiniBox(title: "Лидов", value: "\(store.goals.targetLeads)", color: .orange)
                    }
                }
                .padding(18)
                .liquidGlass(cornerRadius: 26, tint: .cyan, opacity: 0.05)
                
                // Воронка конверсии за все время
                VStack(alignment: .leading, spacing: 12) {
                    Label("Воронка эффективности", systemImage: "chart.bar.fill")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.purple)
                    
                    let total = store.calls.count
                    let talks = store.calls.filter { $0.outcome.countsAsConversation }.count
                    let leads = store.allLeads.count
                    let deals = store.allLeads.filter { $0.leadStage == .closedWon }.count
                    
                    FunnelRow(label: "Всего сделано наборов", count: total, percentOfTotal: 100, color: .cyan)
                    FunnelRow(
                        label: "Состоялось разговоров",
                        count: talks,
                        percentOfTotal: total > 0 ? Int(Double(talks) / Double(total) * 100) : 0,
                        color: .green
                    )
                    FunnelRow(
                        label: "Квалифицировано в Лиды",
                        count: leads,
                        percentOfTotal: total > 0 ? Int(Double(leads) / Double(total) * 100) : 0,
                        color: .orange
                    )
                    FunnelRow(
                        label: "Закрыто в оплату",
                        count: deals,
                        percentOfTotal: leads > 0 ? Int(Double(deals) / Double(leads) * 100) : 0,
                        color: .mint
                    )
                }
                .padding(18)
                .liquidGlass(cornerRadius: 26, tint: .purple, opacity: 0.05)
                
                // Экспорт базы CRM (CSV) и Управление данными
                VStack(alignment: .leading, spacing: 12) {
                    Label("Экспорт базы и Резервная копия", systemImage: "externaldrive.fill.badge.checkmark")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    
                    ShareLink(
                        item: store.exportCSVString(),
                        subject: Text("Выгрузка ColdCall CRM"),
                        message: Text("Моя база звонков и лидов")
                    ) {
                        HStack {
                            Image(systemName: "square.and.arrow.up.fill")
                            Text("Выгрузить все звонки и Лиды в Excel / CSV")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.cyan.opacity(0.2))
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.cyan.opacity(0.45), lineWidth: 1))
                        )
                    }
                    
                    if showClearConfirmation {
                        HStack(spacing: 12) {
                            Button {
                                store.clearAllCalls()
                                showClearConfirmation = false
                            } label: {
                                Text("Подтвердить очистку базы")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.red))
                            }
                            
                            Button {
                                showClearConfirmation = false
                            } label: {
                                Text("Отмена")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.15)))
                            }
                        }
                    } else {
                        Button {
                            showClearConfirmation = true
                        } label: {
                            HStack {
                                Image(systemName: "trash.fill")
                                Text("Очистить тестовые записи")
                                Spacer()
                            }
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.red.opacity(0.9))
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.red.opacity(0.12))
                            )
                        }
                    }
                }
                .padding(18)
                .liquidGlass(cornerRadius: 26)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
    }
}

struct StatMiniBox: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(0.35), lineWidth: 1))
        )
    }
}

struct FunnelRow: View {
    let label: String
    let count: Int
    let percentOfTotal: Int
    let color: Color
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text("\(count)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("(\(percentOfTotal)%)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 11. МОДАЛЬНЫЕ ОКНА: РЕДАКТОР ЦЕЛЕЙ, РЕДАКТОР ЗВОНКА/ЛИДА, НОВЫЙ ЛИД

/// Настройка дневной цели (120 звонков или любое свое число + сколько разговорных)
struct GoalEditorSheet: View {
    @EnvironmentObject var store: CRMStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var totalCalls: Double = 120
    @State private var connectedCalls: Double = 40
    @State private var leadsTarget: Double = 5
    
    var body: some View {
        ZStack {
            LiquidGlassBackground()
            
            VStack(spacing: 22) {
                HStack {
                    Text("Настройка цели на день")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Готово") {
                        store.updateGoals(
                            total: Int(totalCalls),
                            connected: Int(connectedCalls),
                            leads: Int(leadsTarget)
                        )
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.cyan)
                }
                
                // Слайдер общих звонков (по умолчанию 120)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Всего холодных звонков:")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text("\(Int(totalCalls))")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.cyan)
                    }
                    Slider(value: $totalCalls, in: 10...300, step: 5)
                        .tint(.cyan)
                }
                .padding(16)
                .liquidGlass(cornerRadius: 20)
                
                // Слайдер разговорных звонков
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Из них разговорных (дозвонов):")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text("\(Int(connectedCalls))")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.green)
                    }
                    Slider(value: $connectedCalls, in: 5...150, step: 5)
                        .tint(.green)
                }
                .padding(16)
                .liquidGlass(cornerRadius: 20)
                
                // Слайдер Лидов
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Цель по горячим Лидам:")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text("\(Int(leadsTarget))")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                    Slider(value: $leadsTarget, in: 1...30, step: 1)
                        .tint(.orange)
                }
                .padding(16)
                .liquidGlass(cornerRadius: 20)
                
                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            totalCalls = Double(store.goals.targetTotalCalls)
            connectedCalls = Double(store.goals.targetConnectedCalls)
            leadsTarget = Double(store.goals.targetLeads)
        }
    }
}

/// Детальная карточка звонка / Лида (редактирование заметки, суммы, статуса, звонок)
struct CallAndLeadDetailSheet: View {
    @EnvironmentObject var store: CRMStore
    @Environment(\.dismiss) private var dismiss
    
    @State var record: CallRecord
    @State private var dealString: String = ""
    
    var body: some View {
        ZStack {
            LiquidGlassBackground()
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(record.isLead ? "Карточка Лида CRM" : "Детали звонка")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Button("Сохранить") {
                            record.dealAmount = Double(dealString.replacingOccurrences(of: ",", with: ".")) ?? record.dealAmount
                            store.updateCall(record)
                            dismiss()
                        }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                    }
                    
                    // Переключатель Лида
                    Toggle(isOn: $record.isLead) {
                        HStack {
                            Image(systemName: "flame.fill")
                                .foregroundStyle(.orange)
                            Text("Внести / оставить в базе Лидов CRM")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                    .tint(.orange)
                    .padding(14)
                    .liquidGlass(cornerRadius: 18)
                    
                    // Поля контакта
                    VStack(spacing: 12) {
                        GlassTextField(icon: "building.2.fill", placeholder: "Название компании", text: $record.companyName)
                        GlassTextField(icon: "person.fill", placeholder: "Имя контакта / ЛПР", text: $record.contactName)
                        GlassTextField(icon: "phone.fill", placeholder: "Номер телефона", text: $record.phoneNumber, keyboard: .phonePad)
                        GlassTextField(icon: "rublesign.circle.fill", placeholder: "Сумма потенциальной сделки (₽)", text: $dealString, keyboard: .numberPad)
                    }
                    .padding(16)
                    .liquidGlass(cornerRadius: 22)
                    
                    // Статус звонка
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Статус звонка:")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                        
                        Picker("Статус", selection: $record.outcome) {
                            ForEach(CallOutcome.allCases) { outcome in
                                Text(outcome.rawValue).tag(outcome)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(14)
                    .liquidGlass(cornerRadius: 18)
                    
                    // Стадия CRM, если это Лид
                    if record.isLead {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Этап воронки Лида:")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(LeadStage.allCases) { stage in
                                        FilterChip(
                                            title: stage.rawValue,
                                            isSelected: record.leadStage == stage,
                                            color: stage.color
                                        ) {
                                            record.leadStage = stage
                                        }
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .liquidGlass(cornerRadius: 18)
                    }
                    
                    // Большое поле заметки под звонком
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Заметка и договоренности:")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                        
                        TextEditor(text: $record.notes)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(.white)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 130)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.black.opacity(0.35))
                            )
                    }
                    .padding(14)
                    .liquidGlass(cornerRadius: 22)
                    
                    // Удаление звонка
                    Button(role: .destructive) {
                        store.deleteCall(id: record.id)
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "trash.fill")
                            Text("Удалить запись")
                            Spacer()
                        }
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.red)
                        .padding(14)
                        .liquidGlass(cornerRadius: 18)
                    }
                }
                .padding(20)
            }
        }
        .onAppear {
            dealString = record.dealAmount > 0 ? "\(Int(record.dealAmount))" : ""
        }
    }
}

/// Быстрое создание нового Лида напрямую в CRM
struct QuickCreateLeadSheet: View {
    @EnvironmentObject var store: CRMStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var company: String = ""
    @State private var name: String = ""
    @State private var phone: String = ""
    @State private var deal: String = ""
    @State private var stage: LeadStage = .new
    @State private var notes: String = ""
    
    var body: some View {
        ZStack {
            LiquidGlassBackground()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Новый Лид в CRM")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Button("Добавить") {
                            let dealVal = Double(deal.replacingOccurrences(of: ",", with: ".")) ?? 0
                            store.logCall(
                                phone: phone,
                                name: name,
                                company: company,
                                outcome: .lead,
                                notes: notes,
                                isLead: true,
                                dealAmount: dealVal,
                                leadStage: stage
                            )
                            dismiss()
                        }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                    }
                    
                    VStack(spacing: 12) {
                        GlassTextField(icon: "building.2.fill", placeholder: "Компания / Проект", text: $company)
                        GlassTextField(icon: "person.fill", placeholder: "Имя ЛПР", text: $name)
                        GlassTextField(icon: "phone.fill", placeholder: "Телефон", text: $phone, keyboard: .phonePad)
                        GlassTextField(icon: "rublesign.circle.fill", placeholder: "Ожидаемый чек сделки (₽)", text: $deal, keyboard: .numberPad)
                    }
                    .padding(16)
                    .liquidGlass(cornerRadius: 22)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Этап CRM:")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(LeadStage.allCases) { s in
                                    FilterChip(title: s.rawValue, isSelected: stage == s, color: s.color) {
                                        stage = s
                                    }
                                }
                            }
                        }
                    }
                    .padding(14)
                    .liquidGlass(cornerRadius: 18)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Заметка по Лиду:")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                        TextField("О чем договорились, когда перезвонить, что отправить...", text: $notes, axis: .vertical)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(4...8)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.3)))
                    }
                    .padding(14)
                    .liquidGlass(cornerRadius: 20)
                }
                .padding(20)
            }
        }
    }
}
