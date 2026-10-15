package codex

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func catalogFixture(t *testing.T, script string) string {
	t.Helper()
	root := t.TempDir()
	fake := filepath.Join(root, "codex-real")
	if err := os.WriteFile(fake, []byte("#!/usr/bin/env python3\n"+script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", fake)
	return root
}

func TestCatalogPaginatesAndProjectsOnlyPublicModelFields(t *testing.T) {
	root := catalogFixture(t, `import sys,json,os
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 if r['method']=='initialize': result={}
 elif r['method']=='model/list':
  assert os.environ['CODEX_HOME']==os.environ['CAB_EXPECT_HOME']
  cursor=r['params'].get('cursor')
  result={'data':[{'id':'sol','model':'gpt-6.1-sol','displayName':'Sol','description':'Coding','hidden':False,'isDefault':True,'defaultReasoningEffort':'medium','supportedReasoningEfforts':[{'reasoningEffort':'high','description':'Deep'}],'serviceTiers':[{'id':'fast','name':'Fast','description':'Faster'}],'email':'never-export@example.test'}] if cursor is None else [],'nextCursor':'second' if cursor is None else None}
  if cursor is not None: assert cursor=='second'
 print(json.dumps({'id':r['id'],'result':result}),flush=True)
`)
	home := filepath.Join(root, "account")
	t.Setenv("CAB_EXPECT_HOME", home)
	result, err := ReadModels(home)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Models) != 1 || result.Models[0].Model != "gpt-6.1-sol" {
		t.Fatal(result)
	}
	data, _ := json.Marshal(result)
	if strings.Contains(string(data), "never-export") {
		t.Fatal("unrelated account data exposed")
	}
	if err := (LaunchOptions{Model: "gpt-6.1-sol", Effort: "high", Speed: "fast"}).Validate(result); err != nil {
		t.Fatal(err)
	}
	for _, o := range []LaunchOptions{{Speed: "fast"}, {Model: "retired"}, {Model: "gpt-6.1-sol", Effort: "ultra"}, {Model: "gpt-6.1-sol", Speed: "ultrafast"}} {
		if o.Validate(result) == nil {
			t.Fatal("unsupported launch allowed", o)
		}
	}
	if (LaunchOptions{}).Validate(ModelCatalog{}) != nil {
		t.Fatal("official defaults need no catalog")
	}
}

func TestPinningRejectsOldServersThatIgnoreTheField(t *testing.T) {
	root := catalogFixture(t, `import sys,json
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 result={} if r['method']=='initialize' else {'thread':{'id':'task','cwd':'/tmp','updatedAt':1}}
 print(json.dumps({'id':r['id'],'result':result}),flush=True)
`)
	if err := SetTaskPinned(root, "task", true); err == nil {
		t.Fatal("ignored pin reported success")
	}
	for _, id := range []string{"--last", "../task", "", "task\n"} {
		if ValidateTaskID(id) == nil {
			t.Fatal("invalid task accepted", id)
		}
	}
}

func TestTasksDoNotExportPromptsOrTreatFreshServerStatusAsLive(t *testing.T) {
	root := catalogFixture(t, `import sys,json
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 if r['method']=='initialize': result={}
 else:
  assert r['method']=='thread/list'
  assert r['params']['useStateDbOnly']==True
  assert r['params']['cwd']=='/project'
  result={'data':[{'id':'t1','name':'Task','cwd':'/project','updatedAt':10,'isPinned':True,'preview':'PRIVATE PROMPT','status':{'type':'active'},'turns':[{'text':'PRIVATE BODY'}]}],'nextCursor':'next'}
 print(json.dumps({'id':r['id'],'result':result}),flush=True)
`)
	page, err := ReadTasks(root, TaskFilter{Directory: "/project", PinnedOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(page)
	for _, s := range []string{"PRIVATE", "active", "status"} {
		if strings.Contains(string(data), s) {
			t.Fatal("unexpected task data", s)
		}
	}
	if len(page.Tasks) != 1 || page.NextCursor == nil || page.Scope != "stored_history_not_live_runtime" {
		t.Fatal(page)
	}
}

func TestCatalogErrorsDoNotForwardServerSecrets(t *testing.T) {
	root := catalogFixture(t, `import sys,json
for line in sys.stdin:
 r=json.loads(line)
 if 'id' in r: print(json.dumps({'id':r['id'],'error':{'code':-32601,'message':'PRIVATE_TOKEN_OR_URL'}}),flush=True)
`)
	_, err := ReadModels(root)
	if err == nil || strings.Contains(err.Error(), "PRIVATE") {
		t.Fatal(err)
	}
}

func TestLaunchArgumentsPreserveOnlyRequestedOverrides(t *testing.T) {
	args := (LaunchOptions{Model: "gpt-6.1-sol", Effort: "high", Speed: "fast"}).Arguments()
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, `model_reasoning_effort="high"`) || !strings.Contains(joined, `service_tier="fast"`) {
		t.Fatal(joined)
	}
	for _, forbidden := range []string{"sandbox", "approval", "trust"} {
		if strings.Contains(joined, forbidden) {
			t.Fatal(joined)
		}
	}
}
