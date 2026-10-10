// Optional secrets that `wrangler types` can't see unless they're set in .dev.vars.
interface Env {
	CLIENT_KEY?: string;
}
declare namespace Cloudflare {
	interface Env {
		CLIENT_KEY?: string;
	}
}
