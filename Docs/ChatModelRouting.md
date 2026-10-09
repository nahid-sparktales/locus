# Chat models and assigned agent models

A regular chat saves its provider, account ID, and exact model when its first task is accepted. Choosing a model in another chat or changing workspace defaults does not replace that saved route. New chats can choose freely before their first task.

Changing a started chat's model asks for confirmation. Cancel leaves the route and active team unchanged. Confirm affects future messages in that chat; an already submitted or queued task keeps its captured route. The same confirmation applies to the model picker and `/model` command.

In an agent's **Models & providers** section, the primary provider/model is followed by **Assign another model**. An agent can have up to eight assigned models, including different models on the same account or models on different accounts. Account identity is explicit: two accounts with the same display name are never interchangeable.

For an agent with several assigned models, each new task scores its available assigned routes using task tags and the existing model-router scorecards. The preferred model gets the existing stability preference when evidence is limited. If scorecards are unavailable, the first ready assigned model is used. A manual choice in an agent chat pins that chat until **Use agent default** restores automatic selection.

If the selected model cannot start, Locus can try another assigned model. Fallback stops once the model produces an answer, reasoning, or tool activity. An uncertain managed-provider disconnection or timeout does not replay the task. A fallback notice identifies the new model, and the transcript retains one user submission.

Saved profiles and public task snapshots contain model/account references, not credentials. Credentials remain in the existing Keychain/private-runtime configuration. Team tasks additionally respect the existing account consent controls. Existing single-model profiles continue to work without migration.
