"""ollama-code: a local coding agent powered by Ollama."""

__version__ = "0.3.0"

#: The product this agent ships inside. The package keeps its original name
#: so imports stay stable; what users installed is Locus.
PRODUCT_NAME = "Locus"

#: Sent on every outbound HTTP request the agent makes — model providers and
#: any page the model browses — so hosts can see what is calling them. Built
#: from ``__version__`` rather than written out, so it cannot drift the way
#: the old hand-written "ollama-code/0.2" did.
#:
#: Deliberately a constant rather than a setting: Moonshot's Kimi Code terms
#: require third-party tools to identify themselves honestly, and a header
#: that configuration could rewrite is the tampering those terms forbid.
#: Nothing should make this value come from a config file, an environment
#: variable, or a request body.
USER_AGENT = f"{PRODUCT_NAME}-Agent/{__version__} (macOS; io.sparktales.locus)"
