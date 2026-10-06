"""Map shared-host response codes into client actions."""


def action_for_status(status):
    if status == 409:
        return "reload_before_edit"
    if status == 422:
        return "correct_request"
    if status == 503:
        return "retry_when_host_returns"
    return "show_response"
