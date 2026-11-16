def lambda_handler(event, context):
    """Tiny example tool: returns a greeting. The Gateway passes the tool arguments as the event."""
    name = event.get("name", "world") if isinstance(event, dict) else "world"
    return {"message": f"hello, {name}, from the example tool", "received": event}
