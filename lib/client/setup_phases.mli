(** The phases a [bondi setup] run passes through, and what a failure part-way
    through one of them left undone.

    A setup plan is a flat list of actions, but it is built as an ordered
    sequence of phases: Docker, the shared network, cron's curl, the ACME file,
    the orchestrator, alloy, and the managed containers. The interpreter applies
    the list in order and stops at the first action that fails, so every phase
    after that one is skipped — and the operator is told only about the action
    that failed. A run that could not start bondi-alloy reports a container name
    conflict and says nothing about the declared containers it never reached, so
    a host that is part-way through a setup reads as a host that failed at one
    small thing.

    This module turns "which action failed" into "which phases did not run". It
    performs no I/O and knows nothing about actions: the caller maps its own
    actions onto phases and brings them here, which is what keeps the setup
    command's vocabulary in one place. *)

(** One phase of a setup run, in the order the plan emits them. Two actions in
    the same phase are one line in a report: an operator recovering a host wants
    to know that alloy did not run, not that four of its actions did not. *)
type phase =
  | Docker
  | Network
  | Cron_curl
  | Acme
  | Orchestrator
  | Alloy
  | Managed

val unfinished_phases : failed:phase -> remaining:phase list -> phase list
(** The phases that a failure in [failed] left unrun, given the phases of the
    actions that were still ahead of it in the plan.

    Each phase is named once and in the order the plan would have reached it.
    [failed] is never among them: the run stopped part-way through that phase
    rather than skipping it, which is a different thing to tell an operator and
    the more alarming of the two. Empty when the failing action was the last in
    the plan. *)

val failure_message :
  server:string ->
  failed:phase ->
  remaining:phase list ->
  reason:string ->
  string
(** The operator-facing report for an action that failed part-way through a
    setup run.

    Carries [reason] — the failure as the host itself reported it — unedited and
    first, then names [server], the phase the run stopped in, and the phases
    that did not run because of it. When nothing was left to run it says so
    rather than omitting the sentence, so a report that lists no skipped phase
    cannot be mistaken for one that forgot to look.

    [server] is named here rather than prefixed onto [reason] because the caller
    prints every server's failure together at the end of a multi-server run, far
    from the line that announced which server was being processed. Naming it
    once, in the sentence this module owns, is what lets each interpreter arm
    return the host's bare words. *)
