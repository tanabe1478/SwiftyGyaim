import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PI_EDIT_REPLACEMENT_TOOLS = [
  "read_tagged",
  "edit_tagged",
  "read_hashline",
  "edit_hashline_range",
];

export default function replaceEditWithPiEdit(pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    const active = pi.getActiveTools();

    // Respect explicit read-only / custom tool sets. Only replace the built-in
    // edit tool when it would otherwise be active.
    if (!active.includes("edit")) return;

    const available = new Set(pi.getAllTools().map((tool) => tool.name));
    const replacements = PI_EDIT_REPLACEMENT_TOOLS.filter((tool) => available.has(tool));
    const next = [...new Set([...active.filter((tool) => tool !== "edit"), ...replacements])];

    pi.setActiveTools(next);

    const missing = PI_EDIT_REPLACEMENT_TOOLS.filter((tool) => !available.has(tool));
    if (missing.length > 0) {
      ctx.ui.notify(`pi-edit-extension replacement tools missing: ${missing.join(", ")}`, "warning");
    }
  });

  pi.on("before_agent_start", (event) => {
    const active = new Set(pi.getActiveTools());
    if (active.has("edit") || !active.has("edit_tagged")) return;

    return {
      systemPrompt: `${event.systemPrompt}\n\nProject edit policy for SwiftyGyaim:\n- Do not use the built-in edit tool in this repository.\n- For normal existing-file edits, use read_tagged then edit_tagged.\n- For stale-sensitive or repeated edits to the same file, use read_hashline then edit_hashline_range.\n- Use write for creating files and bash for delete/rename/test operations.`,
    };
  });
}
