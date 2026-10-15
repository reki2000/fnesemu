const assert = require('node:assert/strict');
const {mkdtempSync, readFileSync, rmSync} = require('node:fs');
const {tmpdir} = require('node:os');
const {join} = require('node:path');
const {test} = require('node:test');
const verify = require('../scripts/verify-release.cjs');

test('only promote a complete successful full build of the tagged commit', async () => {
  const before = process.cwd();
  const keys = ['COMMIT', 'RELEASE_TAG', 'BUILD_WORKFLOW', 'FOUND_ARTIFACTS'];
  const saved = Object.fromEntries(keys.map(k => [k, process.env[k]]));
  const directory = mkdtempSync(join(tmpdir(), 'mp-build-release-'));
  const names = ['android-all', 'linux-x64', 'linux-arm64', 'windows-x64', 'windows-arm64',
    'macos-universal', 'ios-arm64', 'ios-simulator-arm64', 'web-browser'];
  process.chdir(directory);
  process.env.COMMIT = 'verified-commit';
  process.env.RELEASE_TAG = 'v1.2.3';
  process.env.BUILD_WORKFLOW = 'custom-build.yaml';

  async function check(change, valid) {
    const data = {
      found: [{workflow_run: {id: 42}, expired: false}],
      run: {head_sha: 'verified-commit', workflow_id: 1, status: 'completed', conclusion: 'success',
        event: 'push', head_branch: 'main', html_url: 'ci-url'},
      artifacts: names.map((name, id) => ({name: 'release-' + name, id, expired: false})),
    };
    change(data);
    process.env.FOUND_ARTIFACTS = JSON.stringify(data.found);
    const outputs = {};
    const github = {rest: {actions: {
      getWorkflowRun: async () => ({data: data.run}),
      getWorkflow: async ({workflow_id}) => {
        assert.equal(workflow_id, 'custom-build.yaml');
        return {data: {id: 1}};
      },
      listWorkflowRunArtifacts: () => {},
    }}, paginate: async () => data.artifacts};
    const execute = () => verify({github, context: {repo: {owner: 'owner', repo: 'repo'}},
      core: {setOutput: (key, value) => outputs[key] = value}});
    if (valid) {
      await execute();
      assert.equal(outputs.run_id, 42);
      assert.equal(outputs.artifact_ids, data.artifacts.map(a => a.id).join(','));
      assert.deepEqual(JSON.parse(readFileSync('BUILD-METADATA.json')), {
        tag: 'v1.2.3', commit: 'verified-commit', ci_run: 'ci-url', artifacts: data.artifacts,
      });
    } else await assert.rejects(execute);
  }

  try {
    await check(() => {}, true);
    await check(d => d.run.event = 'workflow_dispatch', true);
    for (const change of [
      d => d.found = [], d => d.found.push(d.found[0]), d => d.found[0].expired = true,
      d => d.run.head_sha = 'different', d => d.run.workflow_id = 2,
      d => d.run.conclusion = 'failure', d => d.run.status = 'in_progress',
      d => d.run.event = 'pull_request', d => d.run.head_branch = 'develop',
      d => d.artifacts.pop(), d => d.artifacts.push(d.artifacts[0]),
      d => d.artifacts[0].expired = true, d => d.artifacts[0].name = 'release-unexpected',
      d => {
        d.artifacts.sort((a, b) => a.name.localeCompare(b.name));
        d.artifacts[0].name += ',' + d.artifacts[1].name;
        d.artifacts.splice(1, 1);
      },
    ]) await check(change, false);
  } finally {
    process.chdir(before);
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    rmSync(directory, {recursive: true, force: true});
  }
});
