"""Freeze approved project checks at admission and enforce normal repair limits."""
from .reusable_checks import ReusableCheckStore, applicable
from .task_state import TaskStateStore, TaskVerifier


class RunChecks:
    def __init__(self, service, run_id, request, *, frozen=None):
        self.service, self.core, self.run_id = service, service.core, run_id
        self.tasks = TaskStateStore(service.run_store)
        self.id = 'run:' + run_id
        existing = self.tasks.get(self.id)
        self.task = self.tasks.ensure(self.id, request=request, revision=(existing or {}).get('revision', 1),
                                      workspace=self.core.workspace_root or self.core.cwd, execution=self.core.cwd,
                                      session_id=self.core.session.session_id, include_reusable=frozen is None)
        if frozen is not None and existing is None:
            from .reusable_checks import scoped_state
            self.task["reusable_checks"] = [{**item, "baseline": scoped_state(self.core.cwd, item["scope"]["files"]) if item["scope"]["files"] else {}} for item in frozen]
            self.tasks.save(self.task, expected_revision=self.task["revision"])

    def verify(self):
        value = self.tasks.get(self.id)
        if not applicable(value) and not value.get('checks'):
            value.update(verification_status='not_applicable', verification_reason='No reusable checks apply to this task.', evidence_ids=[])
            return self.tasks.save(value, expected_revision=value['revision'])
        return TaskVerifier(self.tasks, self.id, self.core, self.run_id).verify([], self.service.decide)

    def reserve_repair(self, limit):
        value = self.tasks.get(self.id)
        if value.get('repair_attempts', 0) >= limit:
            return False
        value['repair_attempts'] = value.get('repair_attempts', 0) + 1
        self.tasks.save(value, expected_revision=value['revision'])
        return True

    def before_finalize(self):
        result = self.verify()
        if result['verification_status'] == 'failed' and self.reserve_repair(1):
            return 'Repair these required checks using the remaining task allowance. Do not repeat uncertain external actions.\n' + result['verification_reason']
        return None

    def terminal(self, event):
        value = self.tasks.get(self.id)
        value["execution_completed"] = event.get("reason") == "complete"
        self.tasks.save(value, expected_revision=value["revision"])
        status, reason = self.tasks.completion(self.id)
        result = {**event, 'verification_status': status, 'verification_reason': reason,
                  'task_contract_id': self.id, 'reusable_checks': self.tasks.get(self.id).get('reusable_checks', [])}
        if event.get('reason') == 'complete' and status not in {'passed', 'not_applicable', 'accepted'}:
            result['reason'] = 'verification_failed' if status == 'failed' else 'needs_review'
        return result


def bind_run_checks(service, run_id, request):
    service.reusable_run_checks = None
    if getattr(service.core, 'goal_runtime', None) or getattr(service.core, 'capsule_runtime', None) or service.core.identity_mode:
        return None
    workspace = service.core.workspace_root or service.core.cwd
    frozen = getattr(service, 'evaluation_frozen_checks', None)
    if frozen is None and not TaskStateStore(service.run_store).get('run:' + run_id) and not any(row['state'] == 'approved' for row in ReusableCheckStore(service.run_store).list(workspace)):
        return None
    runtime = RunChecks(service, run_id, request, frozen=frozen)
    if not runtime.task.get('reusable_checks'):
        return None
    service.reusable_run_checks = runtime
    return runtime
