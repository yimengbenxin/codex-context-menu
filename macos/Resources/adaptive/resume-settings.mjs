export function resumeSettings(result, configuration = {}) {
  const sandbox = result.sandbox;
  const modes = {readOnly: 'read-only', workspaceWrite: 'workspace-write', dangerFullAccess: 'danger-full-access'};
  if (!modes[sandbox?.type]) throw new Error('Current sandbox cannot be preserved by the official resume API');
  const config = {...configuration};
  if (sandbox.type === 'workspaceWrite') config.sandbox_workspace_write = {
    writable_roots: sandbox.writableRoots, network_access: sandbox.networkAccess,
    exclude_tmpdir_env_var: sandbox.excludeTmpdirEnvVar, exclude_slash_tmp: sandbox.excludeSlashTmp};
  if (sandbox.type === 'readOnly' && sandbox.networkAccess)
    throw new Error('Network-enabled read-only policy cannot be preserved by legacy resume');
  if (result.reasoningEffort !== null && result.reasoningEffort !== undefined)
    config.model_reasoning_effort = result.reasoningEffort;
  return {model: result.model, modelProvider: result.modelProvider, cwd: result.cwd,
    serviceTier: result.serviceTier, approvalPolicy: result.approvalPolicy,
    approvalsReviewer: result.approvalsReviewer, sandbox: modes[sandbox.type], config};
}
