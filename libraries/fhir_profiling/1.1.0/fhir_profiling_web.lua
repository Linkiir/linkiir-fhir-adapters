-- ---------------------------------------------------------------------------
-- fhir_profiling_web - HTTP routing + FHIR Profile Designer UI
--
-- Internal module. Serves the FHIR Profile Designer and its JSON API. Receives
-- the multi-version Portal (see fhir_profiling.lua): every data route reads the
-- FHIR version from the request and resolves the matching per-version client,
-- so the served UI can switch release (R4 4.0.1 / R5 5.0.0) without a restart.
--
-- The Designer builds a FHIR JSON *template*: a real FHIR document skeleton for
-- the chosen resource with every leaf set to null, pruned to the required
-- fields plus whichever optional fields the user ticks. That null-template is
-- what the FHIR Resource Creator fills in - there is no invented template
-- format; it is FHIR JSON from the first copy.
--
-- Routes
--   GET  /                                       the Profile Designer UI (HTML)
--   GET  /?action=versions                       JSON list of shipped versions
--   GET  /?action=resources&version=<v>          JSON resource + type name lists
--   GET  /?action=fields&base=<R>&version=<v>    top-level fields { name, required, max, short }
--   GET  /?action=template&base=<R>&version=<v>&fields=<csv> the FHIR JSON null-template
--   GET  /?resource=<name>&version=<v>           full JSON template for a resource/type
--   GET  /?action=elements&base=<R>&version=<v>  full constrainable element list (advanced)
--   POST /?action=build&version=<v>              (advanced) differential builder
--   POST /?action=import                         (advanced) import a profile
--
-- build/import remain for programmatic and future advanced-mode use; the
-- Designer UI does not surface them.
-- ---------------------------------------------------------------------------

local M = {}

-- ---------------------------------------------------------------------------
-- Response helpers
-- ---------------------------------------------------------------------------
local function respondJson(Body, Code)
   linkiir.link.web.respond{ body = Body, contentType = 'application/json', code = Code or 200 }
end
local function respondError(Message, Code)
   respondJson(linkiir.json.serialize({ error = Message }), Code or 400)
end
local function respondHtml(Body, Code)
   linkiir.link.web.respond{ body = Body, contentType = 'text/html; charset=utf-8', code = Code or 200 }
end

local function requestBody(Req, Data)
   if type(Req.body) == 'string' and Req.body ~= '' then return Req.body end
   if type(Req.data) == 'string' and Req.data ~= '' then return Req.data end
   if type(Data) == 'string' and Data ~= '' then return Data end
   return nil
end

local function clientFor(Portal, Params)
   local Version = Params.version
   if not Version or Version == '' then Version = Portal:defaultVersion() end
   local Client, Err = Portal:client(Version)
   if not Client then
      respondError((Err and Err.message) or ('FHIR version not available: ' .. tostring(Version)), 400)
      return nil
   end
   return Client
end

-- Split a comma-separated ?fields= list into a set. Missing/empty -> nil (all).
-- Parse the comma-separated ?fields= list into a set of selected optional
-- fields. Always returns a table (never nil): an empty ?fields= means "nothing
-- optional selected" (required-only), NOT "all fields". The Designer sends the
-- exact selection, so the template reflects only what the user ticked.
local function fieldSet(Csv)
   local Set = {}
   if type(Csv) ~= 'string' then return Set end
   for Name in Csv:gmatch('[^,]+') do
      local Trimmed = Name:gsub('^%s+', ''):gsub('%s+$', '')
      if Trimmed ~= '' then Set[Trimmed] = true end
   end
   return Set
end

-- ---------------------------------------------------------------------------
-- JSON API actions
-- ---------------------------------------------------------------------------
local function serveVersions(Portal)
   respondJson(linkiir.json.serialize({ versions = Portal:versions(), default = Portal:defaultVersion() }))
end

local function serveResources(Client)
   local L = Client:sortedList()
   respondJson(linkiir.json.serialize({ version = Client.version, resources = L.Resources, types = L.Types }))
end

local function serveFields(Client, Params)
   local Base = Params.base or Params.resource
   if not Base or Base == '' then
      respondError('action=fields needs a resource, e.g. ?action=fields&base=Patient'); return
   end
   local Resolved = Client:resolveResourceName(Base) or Base
   local Fields, Err = Client:topLevelFields(Resolved)
   if not Fields then respondError(Err or ('unknown resource: ' .. Base), 404); return end
   respondJson(linkiir.json.serialize({ version = Client.version, resource = Resolved, fields = Fields }))
end

local function serveTemplateForFields(Client, Params)
   local Base = Params.base or Params.resource
   if not Base or Base == '' then
      respondError('action=template needs a resource, e.g. ?action=template&base=Patient'); return
   end
   local Resolved = Client:resolveResourceName(Base) or Base
   local Tmpl, Err = Client:templateFor(Resolved, fieldSet(Params.fields))
   if not Tmpl then respondError(Err or ('unknown resource: ' .. Base), 404); return end
   respondJson(linkiir.json.serialize(Tmpl))
end

local function serveElements(Client, Params)
   local Base = Params.base or Params.resource
   if not Base or Base == '' then respondError('action=elements needs a base resource'); return end
   local Resolved = Client:resolveResourceName(Base) or Base
   local Elements, ElErr = Client:baseElements(Resolved)
   if not Elements then respondError(ElErr or ('unknown base resource: ' .. Base), 404); return end
   respondJson(linkiir.json.serialize({ version = Client.version, base = Resolved, elements = Elements }))
end

local function serveTemplate(Client, Params)
   local ResourceName = Client:resolveResourceName(Params.resource)
   if not ResourceName then respondError('Unrecognized resource/type: ' .. tostring(Params.resource), 404); return end
   local Template = Client:createResource(ResourceName)
   if Template then respondJson(linkiir.json.serialize(Template))
   else respondError('Failed to generate template for: ' .. ResourceName, 500) end
end

local function serveBuild(Client, Body)
   if not Body then respondError('action=build needs a JSON constraint spec in the request body'); return end
   local Ok, Spec = pcall(linkiir.json.parse, Body)
   if not Ok or type(Spec) ~= 'table' then respondError('constraint spec is not valid JSON'); return end
   local Definition, BuildErr = Client:buildProfile(Spec)
   if not Definition then respondError(BuildErr.message, 400); return end
   respondJson(linkiir.json.serialize(Definition))
end

local function serveImport(Client, Body)
   if not Body then respondError('action=import needs a StructureDefinition in the request body'); return end
   local Result, ImportErr = Client:importProfile(Body)
   if not Result then respondError(ImportErr.message, 400); return end
   respondJson(linkiir.json.serialize({
      base = Result.base, hasSnapshot = Result.hasSnapshot,
      editable = Result.editable, definition = Result.definition,
   }))
end

-- ---------------------------------------------------------------------------
-- The FHIR Profile Designer page
--
-- Light + dark theme tokens are transcribed from the Linkiir console design
-- system (frontend/src/index.css), the same approach the DexcomToPCC project's
-- shared ui.lua uses: both ramps ship, switched by prefers-color-scheme, with an
-- explicit data-theme toggle that persists to localStorage. There is no static
-- asset route from a Source HTTP node, so the CSS is inlined here.
-- ---------------------------------------------------------------------------
local PAGE = [==[
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FHIR Profile Designer</title>
<script>(function(){try{var t=localStorage.getItem("lk-theme");
if(t==="dark"||t==="light"){document.documentElement.setAttribute("data-theme",t);}}catch(e){}})();</script>
<style>
:root{
  --brand:#4f46e5;--brand-hover:#4338ca;--brand-contrast:#fff;--brand-tint:#eef2ff;--brand-border:#c7d2fe;--brand-ring:rgba(79,70,229,.28);
  --background:#fafafa;--background-alt:#f4f4f5;--foreground:#09090b;--foreground-body:#3f3f46;
  --border:#e4e4e7;--border-soft:#f4f4f5;--border-strong:#d4d4d8;--card:#fff;--muted:#f4f4f5;--muted-foreground:#71717a;
  --info-bg:#eef2ff;--info-border:#c7d2fe;--info-fg:#4338ca;
  --code-bg:#f8f8fb;--json-key:#8250df;--json-str:#0a7d33;--json-null:#c026d3;--json-punct:#57606a;--gutter:#9aa0aa;
  --radius:.625rem;--shadow:0 1px 2px rgba(9,9,11,.04),0 1px 3px rgba(9,9,11,.06);
}
:root[data-theme="dark"]{
  --brand:#6366f1;--brand-hover:#818cf8;--brand-contrast:#fff;--brand-tint:rgba(99,102,241,.16);--brand-border:rgba(129,140,248,.38);--brand-ring:rgba(129,140,248,.35);
  --background:#0a0a0a;--background-alt:#121212;--foreground:#ededed;--foreground-body:#d4d4d4;
  --border:#262626;--border-soft:#1f1f1f;--border-strong:#333;--card:#121212;--muted:#1a1a1a;--muted-foreground:#8f8f8f;
  --info-bg:rgba(99,102,241,.14);--info-border:rgba(129,140,248,.34);--info-fg:#a5b4fc;
  --code-bg:#0d0d0d;--json-key:#c58fff;--json-str:#3ecf8e;--json-null:#f19bff;--json-punct:#8b93a1;--gutter:#4a4a4a;
  --shadow:0 1px 2px rgba(0,0,0,.5);
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]):not([data-theme="dark"]){
  --brand:#6366f1;--brand-hover:#818cf8;--brand-tint:rgba(99,102,241,.16);--brand-border:rgba(129,140,248,.38);--brand-ring:rgba(129,140,248,.35);
  --background:#0a0a0a;--background-alt:#121212;--foreground:#ededed;--foreground-body:#d4d4d4;
  --border:#262626;--border-soft:#1f1f1f;--border-strong:#333;--card:#121212;--muted:#1a1a1a;--muted-foreground:#8f8f8f;
  --info-bg:rgba(99,102,241,.14);--info-border:rgba(129,140,248,.34);--info-fg:#a5b4fc;
  --code-bg:#0d0d0d;--json-key:#c58fff;--json-str:#3ecf8e;--json-null:#f19bff;--json-punct:#8b93a1;--gutter:#4a4a4a;--shadow:0 1px 2px rgba(0,0,0,.5);
}}
*,*::before,*::after{box-sizing:border-box}
body{margin:0;background:var(--background);color:var(--foreground-body);
  font:400 14px/1.55 Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}
.bar{display:flex;align-items:center;gap:10px;padding:0 20px;height:56px;background:var(--card);border-bottom:1px solid var(--border);position:sticky;top:0;z-index:10}
.logo{color:var(--brand);flex:none}
.brand{font-weight:650;font-size:15px;color:var(--foreground)}
.brand small{display:block;font-weight:400;font-size:11.5px;color:var(--muted-foreground)}
.spacer{flex:1}
.ctrl{display:flex;flex-direction:column;gap:3px}
.ctrl label{font-size:10.5px;letter-spacing:.05em;text-transform:uppercase;color:var(--muted-foreground)}
select{background:var(--card);color:var(--foreground);border:1px solid var(--border-strong);border-radius:8px;padding:8px 10px;font-size:13.5px;outline:none;min-width:150px}
select:focus{border-color:var(--brand);box-shadow:0 0 0 3px var(--brand-ring)}
.hbtn{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--border-strong);background:var(--card);color:var(--foreground);border-radius:8px;padding:8px 12px;font-size:13px;cursor:pointer}
.hbtn:hover{background:var(--background-alt)}
.theme{width:36px;justify-content:center;color:var(--muted-foreground)}
.theme .sun{display:none}.theme .moon{display:block}
:root[data-theme="dark"] .theme .sun{display:block}:root[data-theme="dark"] .theme .moon{display:none}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]):not([data-theme="dark"]) .theme .sun{display:block}
:root:not([data-theme="light"]):not([data-theme="dark"]) .theme .moon{display:none}}
.wrap{max-width:1120px;margin:0 auto;padding:22px 20px 56px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:20px}
@media (max-width:900px){.grid{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow)}
.card h2{font-size:15px;font-weight:650;color:var(--foreground);margin:0}
.chd{padding:18px 20px 12px;border-bottom:1px solid var(--border-soft)}
.chd p{margin:6px 0 0;font-size:12.5px;color:var(--muted-foreground)}
.cbody{padding:14px 16px 18px}
.search{width:100%;background:var(--background-alt);border:1px solid var(--border);border-radius:9px;padding:10px 12px;font-size:13.5px;color:var(--foreground);outline:none;margin-bottom:10px}
.search:focus{border-color:var(--brand)}
.tbtns{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:10px}
.tbtn{border:1px solid var(--border-strong);background:var(--card);color:var(--foreground);border-radius:7px;padding:6px 11px;font-size:12.5px;cursor:pointer}
.tbtn.p{background:var(--brand);color:var(--brand-contrast);border-color:transparent}
.tbtn:hover{background:var(--background-alt)}.tbtn.p:hover{background:var(--brand-hover)}
.count{margin-left:auto;font-size:12px;color:var(--muted-foreground)}
.flds{max-height:520px;overflow:auto;border:1px solid var(--border-soft);border-radius:9px}
.frow{display:flex;align-items:center;gap:10px;padding:9px 12px;border-bottom:1px solid var(--border-soft);font-size:13.5px}
.frow:last-child{border-bottom:none}
.frow:hover{background:var(--background-alt)}
.frow .nm{color:var(--foreground);font-weight:500}
.frow .card-meta{margin-left:auto;display:flex;align-items:center;gap:12px}
.card-card{font-size:11.5px;color:var(--muted-foreground);font-variant-numeric:tabular-nums}
.ty{font-size:12px;color:var(--muted-foreground);min-width:120px}
.cb{width:18px;height:18px;border:1.5px solid var(--border-strong);border-radius:5px;display:grid;place-content:center;cursor:pointer;flex:none;background:var(--card)}
.cb.on{background:var(--brand);border-color:var(--brand)}
.cb.on::after{content:"";width:10px;height:10px;clip-path:polygon(14% 44%,0 60%,40% 100%,100% 20%,84% 6%,38% 66%);background:#fff}
.cb.lock{opacity:.6;cursor:not-allowed}
.req{font-size:10.5px;letter-spacing:.05em;text-transform:uppercase;color:var(--brand);font-weight:600}
.pv-tabs{display:flex;gap:6px}
.pv-tab{border:1px solid var(--border-strong);background:var(--card);color:var(--muted-foreground);border-radius:7px;padding:6px 11px;font-size:12.5px;cursor:pointer}
.pv-tab.on{background:var(--brand);color:var(--brand-contrast);border-color:transparent}
pre{margin:0;background:var(--code-bg);border:1px solid var(--border);border-radius:9px;padding:14px 14px 14px 8px;
  overflow:auto;max-height:520px;font:12.5px/1.6 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--foreground)}
.ln{display:block;white-space:pre}.gut{display:inline-block;width:2.4em;text-align:right;color:var(--gutter);margin-right:1em;user-select:none}
.k{color:var(--json-key)}.s{color:var(--json-str)}.nul{color:var(--json-null)}.pu{color:var(--json-punct)}
.acts{display:flex;gap:10px;padding:12px 16px 0}
.abtn{flex:1;display:inline-flex;align-items:center;justify-content:center;gap:7px;border:1px solid var(--border-strong);background:var(--card);color:var(--foreground);border-radius:9px;padding:11px;font-size:13.5px;cursor:pointer}
.abtn.done{border-color:var(--info-fg);color:var(--info-fg)}
.abtn:hover{background:var(--background-alt)}
.note{margin:14px 16px 0;background:var(--info-bg);border:1px solid var(--info-border);border-left:3px solid var(--info-fg);border-radius:8px;padding:11px 13px;font-size:12.5px;color:var(--foreground-body)}
.note b{color:var(--foreground)}
.err{color:#e5484d;font-size:12.5px;padding:6px 16px 0;min-height:1px}
</style>
</head>
<body>
<header class="bar">
  <svg class="logo" width="26" height="26" viewBox="0 0 32 32" fill="none" aria-hidden="true"><g transform="translate(0,4)"><circle cx="11" cy="12" r="9" stroke="currentColor" stroke-width="1.75"/><circle cx="21" cy="12" r="9" stroke="currentColor" stroke-width="1.75"/></g></svg>
  <div class="brand">FHIR Profile Designer<small>Build a FHIR JSON template using preloaded R4 / R5 definitions</small></div>
  <span class="spacer"></span>
  <div class="ctrl"><label for="version">FHIR Version</label><select id="version"></select></div>
  <div class="ctrl"><label for="resource">Resource</label><select id="resource"></select></div>
  <button class="hbtn theme" onclick="toggleTheme()" title="Toggle theme" aria-label="Toggle theme">
    <svg class="moon" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>
    <svg class="sun" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4.5"/><path d="M12 1.5v2M12 20.5v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M1.5 12h2M20.5 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4"/></svg>
  </button>
</header>

<div class="wrap"><div class="grid">
  <div class="card">
    <div class="chd"><h2>Choose Fields</h2><p>Select the fields to include in the JSON template. Required fields are checked and locked.</p></div>
    <div class="cbody">
      <input class="search" id="search" placeholder="Search fields (e.g. name, identifier, birthDate)">
      <div class="tbtns">
        <button class="tbtn" id="selAll">Select All</button>
        <button class="tbtn" id="unselAll">Unselect All</button>
        <button class="tbtn" id="selOnly">Selected Only</button>
        <span class="count" id="count"></span>
      </div>
      <div class="flds" id="fields"></div>
      <div class="err" id="err"></div>
    </div>
  </div>

  <div class="card">
    <div class="chd" style="display:flex;align-items:flex-start;justify-content:space-between;gap:12px">
      <div><h2>FHIR JSON Preview</h2><p>A FHIR template with null placeholders. The Resource Creator replaces nulls with real data.</p></div>
      <div class="pv-tabs"><button class="pv-tab on" data-v="json">JSON</button><button class="pv-tab" data-v="tree">Tree</button></div>
    </div>
    <div class="cbody">
      <pre id="preview"></pre>
      <div class="acts">
        <button class="abtn" id="copyBtn">Copy JSON</button>
        <button class="abtn" id="dlBtn">Download</button>
      </div>
      <div class="note"><b>Where this goes:</b> Copy this JSON and paste it into the <b>Template</b> field of a <b>FHIR Resource Creator</b> node (Edit &rarr; Template). The Creator fills the null placeholders from your mapped input fields. Null values are placeholders for mapping; optional elements left unselected are omitted, required elements are always present.</div>
    </div>
  </div>
</div></div>

<script>
"use strict";
var API=location.pathname;
var st={version:null,versions:[],resource:null,fields:[],selected:{},template:{},tab:"json"};
function q(id){return document.getElementById(id);}
function api(p){var u=new URL(API,location.origin);Object.keys(p).forEach(function(k){u.searchParams.set(k,p[k]);});
  return fetch(u.toString(),{headers:{Accept:"application/json"}}).then(function(r){return r.json();});}
function setErr(m){q("err").textContent=m||"";}
function toggleTheme(){var r=document.documentElement,c=r.getAttribute("data-theme"),n=c==="dark"?"light":"dark";
  r.setAttribute("data-theme",n);try{localStorage.setItem("lk-theme",n);}catch(e){}}

function selectedList(){return st.fields.filter(function(f){return st.selected[f.name];}).map(function(f){return f.name;});}
function refreshCount(){q("count").textContent="Total: "+selectedList().length+" selected";}

function renderFields(){
  var host=q("fields");host.innerHTML="";
  var term=(q("search").value||"").toLowerCase();
  st.fields.forEach(function(f){
    if(term && f.name.toLowerCase().indexOf(term)<0) return;
    if(st.onlySelected && !st.selected[f.name]) return;
    var row=document.createElement("div");row.className="frow";
    var cb=document.createElement("div");
    cb.className="cb"+(st.selected[f.name]?" on":"")+(f.required?" lock":"");
    cb.addEventListener("click",function(){ if(f.required)return; st.selected[f.name]=!st.selected[f.name];
      cb.className="cb"+(st.selected[f.name]?" on":""); refreshCount(); loadTemplate(); });
    var nm=document.createElement("div");nm.className="nm";nm.textContent=f.name;
    var meta=document.createElement("div");meta.className="card-meta";
    var card=document.createElement("span");card.className="card-card";card.textContent=(f.max==="*"?"0..*":"0.."+(f.max||"1"));
    meta.appendChild(card);
    if(f.required){var r=document.createElement("span");r.className="req";r.textContent="Required";meta.appendChild(r);}
    row.appendChild(cb);row.appendChild(nm);row.appendChild(meta);host.appendChild(row);
  });
  refreshCount();
}

function highlight(json){
  return json.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")
    .replace(/"([^"]+)":/g,'<span class="k">"$1"</span><span class="pu">:</span>')
    .replace(/: "([^"]*)"/g,': <span class="s">"$1"</span>')
    .replace(/\bnull\b/g,'<span class="nul">null</span>')
    .replace(/([{}\[\],])/g,'<span class="pu">$1</span>');
}
function renderPreview(){
  var pre=q("preview");
  var text=JSON.stringify(st.template,null,2);
  if(st.tab==="tree"){ pre.textContent=text; return; }
  var lines=text.split("\n"),out="";
  for(var i=0;i<lines.length;i++){ out+='<span class="ln"><span class="gut">'+(i+1)+'</span>'+highlight(lines[i])+'</span>'; }
  pre.innerHTML=out;
}

function loadTemplate(){
  api({action:"template",base:st.resource,version:st.version,fields:selectedList().join(",")}).then(function(d){
    if(d.error){setErr(d.error);return;} setErr(""); st.template=d; renderPreview();
  }).catch(function(e){setErr(String(e));});
}
function loadFields(){
  setErr(""); st.resource=q("resource").value;
  api({action:"fields",base:st.resource,version:st.version}).then(function(d){
    if(d.error){setErr(d.error);st.fields=[];renderFields();return;}
    st.fields=d.fields||[]; st.selected={};
    st.fields.forEach(function(f){ if(f.required) st.selected[f.name]=true; });
    renderFields(); loadTemplate();
  }).catch(function(e){setErr(String(e));});
}
function loadResources(){
  api({action:"resources",version:st.version}).then(function(d){
    var sel=q("resource");sel.innerHTML="";
    (d.resources||[]).forEach(function(n){var o=document.createElement("option");o.value=n;o.textContent=n;sel.appendChild(o);});
    if((d.resources||[]).indexOf("Patient")>=0) sel.value="Patient";
    loadFields();
  });
}
function init(){
  api({action:"versions"}).then(function(d){
    st.versions=d.versions||[]; st.version=d.default||st.versions[0];
    var sel=q("version");sel.innerHTML="";
    st.versions.forEach(function(v){var o=document.createElement("option");o.value=v;
      o.textContent=(v.indexOf("4.")===0?"R4 ("+v+")":(v.indexOf("5.")===0?"R5 ("+v+")":v));sel.appendChild(o);});
    if(st.version) sel.value=st.version;
    loadResources();
  });
  q("version").addEventListener("change",function(){st.version=q("version").value;loadResources();});
  q("resource").addEventListener("change",loadFields);
  q("search").addEventListener("input",renderFields);
  q("selAll").addEventListener("click",function(){st.fields.forEach(function(f){st.selected[f.name]=true;});renderFields();loadTemplate();});
  q("unselAll").addEventListener("click",function(){
    // Required fields stay selected and locked; everything optional is cleared.
    st.fields.forEach(function(f){st.selected[f.name]=!!f.required;});renderFields();loadTemplate();});
  q("selOnly").addEventListener("click",function(){
    st.onlySelected=!st.onlySelected;
    q("selOnly").classList.toggle("p", st.onlySelected);
    renderFields();
  });
  Array.prototype.forEach.call(document.querySelectorAll(".pv-tab"),function(t){
    t.addEventListener("click",function(){Array.prototype.forEach.call(document.querySelectorAll(".pv-tab"),function(x){x.classList.remove("on");});
      t.classList.add("on");st.tab=t.getAttribute("data-v");renderPreview();});
  });
  q("copyBtn").addEventListener("click",function(){
    navigator.clipboard.writeText(JSON.stringify(st.template,null,2)).then(function(){
      var b=q("copyBtn");b.classList.add("done");var t=b.textContent;b.textContent="Copied";
      setTimeout(function(){b.classList.remove("done");b.textContent=t;},1400);});
  });
  q("dlBtn").addEventListener("click",function(){
    var blob=new Blob([JSON.stringify(st.template,null,2)],{type:"application/json"});
    var a=document.createElement("a");a.href=URL.createObjectURL(blob);
    a.download=(st.resource||"resource")+"_template.json";a.click();URL.revokeObjectURL(a.href);
  });
}
document.addEventListener("DOMContentLoaded",init);
</script>
</body>
</html>
]==]

-- ---------------------------------------------------------------------------
-- Public: serve a request
-- ---------------------------------------------------------------------------
function M.serve(Portal, Data)
   local Req = linkiir.link.web.request{ data = Data }
   local Params = Req.params or {}
   local Action = Params.action

   if Action == 'versions' then serveVersions(Portal); return end

   if Action == 'import' then
      local Client = clientFor(Portal, Params); if not Client then return end
      serveImport(Client, requestBody(Req, Data)); return
   elseif Action == 'resources' then
      local Client = clientFor(Portal, Params); if not Client then return end
      serveResources(Client); return
   elseif Action == 'fields' then
      local Client = clientFor(Portal, Params); if not Client then return end
      serveFields(Client, Params); return
   elseif Action == 'template' then
      local Client = clientFor(Portal, Params); if not Client then return end
      serveTemplateForFields(Client, Params); return
   elseif Action == 'elements' then
      local Client = clientFor(Portal, Params); if not Client then return end
      serveElements(Client, Params); return
   elseif Action == 'build' then
      local Client = clientFor(Portal, Params); if not Client then return end
      serveBuild(Client, requestBody(Req, Data)); return
   elseif Action ~= nil then
      respondError('Unknown action: ' .. tostring(Action), 400); return
   end

   if Params.resource then
      local Client = clientFor(Portal, Params); if not Client then return end
      serveTemplate(Client, Params); return
   end

   respondHtml(PAGE)
end

return M
