"""Capability-aware planning policy used by both provider execution paths."""


def planning_contract(mode: str, *, native: bool = False, available_tools=None) -> str:
    preferred = "ask_user_question" if native else "ask_question"
    if available_tools is not None:
        preferred = next((name for name in (preferred, "ask_question", "ask_user_question") if name in available_tools), "")
    question = (f"Deliver material questions with {preferred}; follow its returned waiting instructions. "
                "While an optional question is pending, continue only independent work. " if preferred else
                "If a material decision cannot be inferred, ask one concise question in prose and wait for an answer. ")
    common = ("Discover repository facts yourself. Ask only about material decisions that change the result. "
              "Stop planning when material decisions, interfaces, constraints and acceptance criteria are settled. "
              "Record remaining low-impact assumptions. Use deliverable-sized steps; do not prewrite every line, "
              "require micro-commits, or ask again which execution method to use. ")
    if mode == "plan":
        return common + question + " Stay read-only. Call submit_plan exactly once with the final decision-complete plan and its acceptance checks."
    if mode == "grill":
        return common + question + (" Ask one consequential question at a time. Explore every branch only when the user "
            "explicitly requests exhaustive grilling. Stay read-only until the user requests implementation.")
    if mode in {"work", "build"}:
        return "For clear, small, reversible tasks, work directly and run a relevant check. " + common
    return ""
