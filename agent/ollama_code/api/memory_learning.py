"""Authenticated memory learning review; model tools cannot approve procedures."""
from __future__ import annotations

import asyncio
from typing import Any

from fastapi import APIRouter, Body, HTTPException
from locus_memory.errors import MemoryEngineError, NotFound
from locus_memory.models import ProcedureDraft, Scope

from ..evaluations import EvaluationStore
from ..memory_learning import (
    ApprovedProcedureRunner,
    LearningError,
    ProcedureSuiteBindings,
    learning_context,
    learning_engine,
    refresh_episode_evidence,
)
from ..task_state import digest
from .continuity import ServiceDependency


def _context(service, write=False):
    try:
        return learning_context(service, write=write)
    except (LearningError, MemoryEngineError) as exc:
        raise HTTPException(409, str(exc)) from exc


def _procedure(engine, access, identifier):
    try:
        return engine.get_procedure(access, identifier)
    except NotFound as exc:
        raise HTTPException(404, 'Procedure not found in this agent namespace.') from exc


def episodes(service: ServiceDependency):
    adapter, access, _ = _context(service)
    return {'episodes': [e.to_dict() for e in adapter.engine.list_episodes(access, limit=100)]}


def procedures(service: ServiceDependency):
    adapter, access, _ = _context(service)
    return {'procedures': [p.to_dict() for p in adapter.engine.list_procedures(access, limit=100)]}


def procedure_evaluation_suites(service: ServiceDependency):
    _, access, _ = _context(service)
    if not access.grants.projects:
        raise HTTPException(403, 'Workspace memory is not permitted for this agent.')
    workspace = service.core.workspace_root or service.core.cwd
    return {'suites': [{'suite': suite, 'fingerprint': digest(suite)}
                      for suite in EvaluationStore(service.run_store).list_suites(workspace)]}


def nominate(service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict)):
    adapter, access, agent_id = _context(service, True)
    workspace = next(iter(access.grants.projects), None)
    if not workspace:
        raise HTTPException(403, 'Workspace memory is not permitted for this agent.')
    visibility = body.get('visibility', 'agent')
    if visibility not in {'workspace', 'agent'} or visibility == 'agent' and agent_id not in access.grants.agents:
        raise HTTPException(422, 'Choose an allowed agent or workspace scope.')
    try:
        draft = ProcedureDraft.from_dict({**body, 'scope': Scope.of(project=workspace,
            agent=agent_id if visibility == 'agent' else None).as_dict()})
        refresh_episode_evidence(service, draft.evidence_episode_ids)
        procedure, _ = adapter.engine.nominate_procedure(access, draft)
        return {'procedure': procedure.to_dict()}
    except (ValueError, MemoryEngineError) as exc:
        raise HTTPException(422, str(exc)) from exc


def approve_evaluation(procedure_id: str, service: ServiceDependency,
                       body: dict[str, Any] = Body(default_factory=dict)):
    adapter, access, agent_id = _context(service, True)
    procedure = _procedure(adapter.engine, access, procedure_id)
    if body.get('approved') is not True or body.get('expected_version') != procedure.version:
        raise HTTPException(422, 'Explicit review of this procedure version and suite is required.')
    suite = EvaluationStore(service.run_store).get_suite(str(body.get('suite_id') or ''))
    if not suite:
        raise HTTPException(404, 'Evaluation suite not found.')
    if body.get('expected_suite_fingerprint') != digest(suite):
        raise HTTPException(409, 'The displayed evaluation suite changed. Refresh and review it again.')
    try:
        value = ProcedureSuiteBindings(service.run_store).approve(procedure, suite,
            workspace=service.core.workspace_root or service.core.cwd, agent_id=agent_id,
            negative_case_ids=body.get('negative_case_ids') or [])
        return {'approval': value}
    except (ValueError, MemoryEngineError) as exc:
        raise HTTPException(422, str(exc)) from exc


async def evaluate(procedure_id: str, service: ServiceDependency,
                   body: dict[str, Any] = Body(default_factory=dict)):
    adapter, access, _ = _context(service, True)
    procedure = _procedure(adapter.engine, access, procedure_id)
    if body.get('expected_version') != procedure.version:
        raise HTTPException(409, 'Refresh the procedure before evaluating.')
    deadline = body.get('deadline_s', 300)
    if type(deadline) not in (int, float) or not 1 <= deadline <= 3600:
        raise HTTPException(422, 'deadline_s must be between 1 and 3600.')
    def execute():
        try:
            if service.core._interrupt.is_set():
                raise LearningError('Procedure evaluation was cancelled before execution.')
            fresh_adapter, fresh_access, _ = learning_context(service, write=True)
            current = _procedure(fresh_adapter.engine, fresh_access, procedure_id)
            if current.version != procedure.version:
                raise LearningError('The procedure changed before evaluation started.')
            refresh_episode_evidence(service, procedure.evidence_episode_ids)
            with learning_engine(fresh_adapter, runner=ApprovedProcedureRunner(service, current)) as engine:
                result, _ = engine.evaluate_procedure(fresh_access, procedure_id, deadline_s=float(deadline))
                service.emit({'type': 'memory_procedure_evaluated', 'procedure_id': result.procedure_id,
                              'state': result.state.value})
        except (LearningError, MemoryEngineError, HTTPException) as exc:
            service.emit({'type': 'memory_procedure_evaluated', 'procedure_id': procedure_id,
                          'state': 'unavailable', 'error_type': type(exc).__name__})
    if not service.start_turn(asyncio.get_running_loop(), execute, reset_interrupt=True):
        raise HTTPException(409, 'The agent is busy.')
    return {'procedure_id': procedure_id, 'state': 'queued'}


def approve(procedure_id: str, service: ServiceDependency,
            body: dict[str, Any] = Body(default_factory=dict)):
    adapter, access, _ = _context(service, True)
    if body.get('approved') is not True:
        raise HTTPException(422, 'Human approval is required.')
    try:
        procedure = _procedure(adapter.engine, access, procedure_id)
        refresh_episode_evidence(service, procedure.evidence_episode_ids)
        procedure, _ = adapter.engine.approve_procedure(access, procedure_id,
            expected_version=body.get('expected_version'))
        return {'procedure': procedure.to_dict(), 'installed': False}
    except (ValueError, MemoryEngineError) as exc:
        raise HTTPException(422, str(exc)) from exc


def reject(procedure_id: str, service: ServiceDependency,
           body: dict[str, Any] = Body(default_factory=dict)):
    adapter, access, _ = _context(service, True)
    try:
        procedure, _ = adapter.engine.reject_procedure(access, procedure_id, str(body.get('reason') or '')[:2000])
        return {'procedure': procedure.to_dict()}
    except (ValueError, MemoryEngineError) as exc:
        raise HTTPException(422, str(exc)) from exc


def register_routes(router: APIRouter):
    router.add_api_route('/api/memory/episodes', episodes, methods=['GET'])
    router.add_api_route('/api/memory/procedures', procedures, methods=['GET'])
    router.add_api_route('/api/memory/procedure-evaluation-suites', procedure_evaluation_suites, methods=['GET'])
    router.add_api_route('/api/memory/procedures/nominate', nominate, methods=['POST'])
    router.add_api_route('/api/memory/procedures/{procedure_id}/evaluation-approval', approve_evaluation, methods=['POST'])
    router.add_api_route('/api/memory/procedures/{procedure_id}/evaluate', evaluate, methods=['POST'])
    router.add_api_route('/api/memory/procedures/{procedure_id}/approve', approve, methods=['POST'])
    router.add_api_route('/api/memory/procedures/{procedure_id}/reject', reject, methods=['POST'])
