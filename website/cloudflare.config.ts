import { defineConfig, triggers } from "cf/config";

// ClaudeBar's website: the landing page, the leaderboard page and its globe.
// Static assets only (free, cached, not counted as Worker requests); the
// leaderboard reads https://claudebar-api.tddworks.com, a separate Worker.
export default defineConfig({
	worker: {
		name: "claudebar-site",
		compatibilityDate: "2026-08-22",
		assets: {
			htmlHandling: "auto-trailing-slash",
			notFoundHandling: "404-page",
		},
		triggers: [
			// DNS: a proxied AAAA 100:: record for claudebar.tddworks.com.
			triggers.fetch({ pattern: "claudebar.tddworks.com/*", zone: "tddworks.com" }),
		],
	},
});
