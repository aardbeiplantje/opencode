# install the apport exception handler if available
try:
    import apport_python_hook
except ImportError:
    pass
else:
    apport_python_hook.install()

try:
    import litellm
except ImportError:
    pass
else:

    def _llamacpp_registered():
        for entry in litellm.custom_provider_map:
            if entry.get("provider") == "llamacpp":
                return True
        return False


    if not _llamacpp_registered():
        from cocoindex_plugins.llamacpp_provider import _build_handler
        handler = _build_handler()
        litellm.custom_provider_map.append({
            "provider": "llamacpp",
            "custom_handler": handler
        })
