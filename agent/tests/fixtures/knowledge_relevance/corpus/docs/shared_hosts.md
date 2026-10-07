# Shared execution hosts

Two desktops can connect to one running Harbor host over SSH. The host owns the
workspace index and saved notes; both controllers see the same revisions.

## Availability

If the host is asleep or disconnected, its notes cannot be searched or changed.
Keep the host awake while using its agents. A desktop keeps its own local notes
for local sessions, but does not download a second copy of the remote notebook.
There is no offline replication or automatic reconciliation after a disconnect.

## Ownership

A worker's workspace and profile select the visible notes. Different checkout
paths on the same host remain separate workspaces. The controller cannot select
an arbitrary profile by editing a forwarded request body.
