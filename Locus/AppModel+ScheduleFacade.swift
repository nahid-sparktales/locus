import Foundation

/// Forwarders kept while consumers still reach schedules through AppModel;
/// each is deleted once its last caller observes `model.schedule` directly.
extension AppModel {
    var scheduledTasks: [ScheduledTask] { schedule.scheduledTasks }
    var nextScheduledTask: ScheduledTask? { schedule.nextScheduledTask }
    var isSavingSchedule: Bool { schedule.isSavingSchedule }
    var isRefreshingSchedules: Bool { schedule.isRefreshingSchedules }

    var scheduleEditorDraft: ScheduleEditorDraft? {
        get { schedule.scheduleEditorDraft }
        set { schedule.scheduleEditorDraft = newValue }
    }

    func refreshScheduledTasks(announceFailure: Bool = true) async {
        await schedule.refreshScheduledTasks(announceFailure: announceFailure)
    }

    func saveSchedule(_ draft: ScheduleEditorDraft) async -> Bool {
        await schedule.saveSchedule(draft)
    }

    func setScheduleEnabled(_ task: ScheduledTask, enabled: Bool) {
        schedule.setScheduleEnabled(task, enabled: enabled)
    }

    func deleteSchedule(_ task: ScheduledTask) { schedule.deleteSchedule(task) }
    func runScheduleNow(_ task: ScheduledTask) { schedule.runScheduleNow(task) }
    func openLatestRun(for task: ScheduledTask) { schedule.openLatestRun(for: task) }

    func processDueSchedules(now: Date = Date()) async {
        await schedule.processDueSchedules(now: now)
    }

    func dispatchSchedule(
        _ task: ScheduledTask, trigger: String, requestID: String,
        announceFailure: Bool
    ) async {
        await schedule.dispatchSchedule(
            task, trigger: trigger, requestID: requestID, announceFailure: announceFailure
        )
    }

    func replaceScheduledTask(_ task: ScheduledTask) {
        schedule.replaceScheduledTask(task)
    }
}
