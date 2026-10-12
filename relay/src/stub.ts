/** The relay's one Hub, which holds the host's connection and the relay's state. */
export function hub(env: Env) {
	return env.HUB.get(env.HUB.idFromName("default"));
}
