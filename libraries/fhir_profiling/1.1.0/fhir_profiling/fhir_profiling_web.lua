-- ---------------------------------------------------------------------------
-- fhir_profiling_web - HTTP request routing + Profile Designer UI
--
-- Internal module. Serves the FHIR Profiling Tools portal and its JSON API.
-- Receives the multi-version Portal (see fhir_profiling.lua): every data route
-- reads the FHIR version from the request and resolves the matching per-version
-- client, so the served UI can switch release (R4 4.0.1 / R5 5.0.0) without a
-- node restart.
--
-- Routes
--   GET  /                                     the Profile Designer UI (HTML)
--   GET  /?action=versions                     JSON list of shipped versions
--   GET  /?action=resources&version=<v>        JSON resource + type name lists
--   GET  /?resource=<name>&version=<v>         JSON template for a resource/type
--   GET  /?action=elements&base=<R>&version=<v> constrainable elements of a base
--   POST /?action=build&version=<v>            body = constraint spec, returns a
--                                              differential StructureDefinition
--   POST /?action=import                       body = StructureDefinition, returns
--                                              it parsed with editable constraints
--
-- The authoring routes let the browser UI compose a profile by calling the
-- node's own Lua - the same buildProfile a workflow would use - rather than
-- duplicating the logic in JavaScript.
-- ---------------------------------------------------------------------------

local M = {}

-- ---------------------------------------------------------------------------
-- Response helpers
-- ---------------------------------------------------------------------------
local function respondJson(Body, Code)
   linkiir.link.web.respond{
      body        = Body,
      contentType = 'application/json',
      code        = Code or 200,
   }
end

local function respondError(Message, Code)
   respondJson(linkiir.json.serialize({ error = Message }), Code or 400)
end

local function respondHtml(Body, Code)
   linkiir.link.web.respond{
      body        = Body,
      contentType = 'text/html',
      code        = Code or 200,
   }
end

-- The request body, from whichever field the inbound-request table exposes it
-- under. Tolerant because a POST body may arrive as .body, .data, or the raw
-- Data string depending on how the request was delivered.
local function requestBody(Req, Data)
   if type(Req.body) == 'string' and Req.body ~= '' then return Req.body end
   if type(Req.data) == 'string' and Req.data ~= '' then return Req.data end
   if type(Data) == 'string' and Data ~= '' then return Data end
   return nil
end

-- Resolve the client for the request's ?version=, or send an error response.
-- Returns the client, or nil when it already responded with the error.
local function clientFor(Portal, Params)
   local Version = Params.version
   if not Version or Version == '' then
      Version = Portal:defaultVersion()
   end
   local Client, Err = Portal:client(Version)
   if not Client then
      respondError((Err and Err.message) or ('FHIR version not available: ' .. tostring(Version)), 400)
      return nil
   end
   return Client
end

-- ---------------------------------------------------------------------------
-- JSON API actions
-- ---------------------------------------------------------------------------
local function serveVersions(Portal)
   respondJson(linkiir.json.serialize({
      versions = Portal:versions(),
      default  = Portal:defaultVersion(),
   }))
end

local function serveResources(Client)
   local SortedList = Client:sortedList()
   respondJson(linkiir.json.serialize({
      version   = Client.version,
      resources = SortedList.Resources,
      types     = SortedList.Types,
   }))
end

local function serveElements(Client, Params)
   local Base = Params.base or Params.resource
   if not Base or Base == '' then
      respondError('action=elements needs a base resource, e.g. ?action=elements&base=Patient')
      return
   end
   local Resolved = Client:resolveResourceName(Base) or Base
   local Elements, ElErr = Client:baseElements(Resolved)
   if not Elements then
      respondError(ElErr or ('unknown base resource: ' .. Base), 404)
      return
   end
   respondJson(linkiir.json.serialize({
      version  = Client.version,
      base     = Resolved,
      elements = Elements,
   }))
end

local function serveTemplate(Client, Params)
   local ResourceName = Client:resolveResourceName(Params.resource)
   if not ResourceName then
      respondError('Unrecognized resource/type: ' .. tostring(Params.resource), 404)
      return
   end
   local Template = Client:createResource(ResourceName)
   if Template then
      respondJson(linkiir.json.serialize(Template))
   else
      respondError('Failed to generate template for: ' .. ResourceName, 500)
   end
end

local function serveBuild(Client, Body)
   if not Body then
      respondError('action=build needs a JSON constraint spec in the request body')
      return
   end
   local Ok, Spec = pcall(linkiir.json.parse, Body)
   if not Ok or type(Spec) ~= 'table' then
      respondError('constraint spec is not valid JSON')
      return
   end
   local Definition, BuildErr = Client:buildProfile(Spec)
   if not Definition then
      respondError(BuildErr.message, 400)
      return
   end
   respondJson(linkiir.json.serialize(Definition))
end

local function serveImport(Client, Body)
   if not Body then
      respondError('action=import needs a StructureDefinition in the request body')
      return
   end
   local Result, ImportErr = Client:importProfile(Body)
   if not Result then
      respondError(ImportErr.message, 400)
      return
   end
   respondJson(linkiir.json.serialize({
      base        = Result.base,
      hasSnapshot = Result.hasSnapshot,
      editable    = Result.editable,
      definition  = Result.definition,
   }))
end

-- ---------------------------------------------------------------------------
-- The Profile Designer page (HTML + CSS + inline JS, no build step)
-- ---------------------------------------------------------------------------
local PAGE = [==[
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FHIR Profile Designer</title>
<style>
  :root{
    --bg:#0b0d10; --panel:#14171c; --panel2:#1b1f26; --line:#262b33;
    --text:#e6e9ef; --muted:#8b93a1; --accent:#6d5efc; --accent2:#8b7bff;
    --ok:#3ecf8e; --code:#0e1116;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);
    font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
  .wrap{max-width:860px;margin:0 auto;padding:28px 20px 64px;}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:16px;
    padding:26px 26px 30px;box-shadow:0 1px 0 rgba(255,255,255,.02),0 20px 40px -30px #000;}
  .top{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:22px;}
  h1{font-size:22px;font-weight:650;margin:0;letter-spacing:.2px;}
  .pill{background:rgba(109,94,252,.16);color:var(--accent2);border:1px solid rgba(109,94,252,.35);
    font-size:12px;padding:6px 12px;border-radius:999px;white-space:nowrap;}
  .profileBox{background:var(--panel2);border:1px solid var(--line);border-radius:12px;
    padding:16px 18px;margin-bottom:22px;}
  .profileBox .lbl{font-size:11px;letter-spacing:.14em;color:var(--muted);text-transform:uppercase;}
  .profileBox .nm{font-size:18px;font-weight:600;margin:4px 0 2px;}
  .profileBox .sub{color:var(--muted);font-size:13px;}
  label.fld{display:block;font-size:13px;color:var(--muted);margin:18px 0 7px;}
  .row{display:flex;gap:12px;flex-wrap:wrap;}
  .row > div{flex:1;min-width:180px;}
  select,input[type=text]{width:100%;background:var(--code);color:var(--text);
    border:1px solid var(--line);border-radius:11px;padding:12px 14px;font-size:15px;outline:none;}
  select:focus,input:focus{border-color:var(--accent);}
  h2{font-size:16px;font-weight:650;margin:26px 0 4px;}
  .hint{color:var(--muted);font-size:12.5px;margin:0 0 12px;}
  .constraints{border-top:1px solid var(--line);margin-top:6px;}
  .crow{display:flex;align-items:center;justify-content:space-between;gap:14px;
    padding:12px 2px;border-bottom:1px solid var(--line);}
  .crow .path{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13.5px;}
  .crow .card-note{color:var(--muted);font-size:12px;}
  .toggles{display:flex;gap:20px;align-items:center;}
  .tg{display:flex;align-items:center;gap:8px;cursor:pointer;user-select:none;color:var(--muted);font-size:13px;}
  .tg input{appearance:none;width:20px;height:20px;border-radius:50%;border:1.5px solid #3a414c;
    background:transparent;display:grid;place-content:center;cursor:pointer;margin:0;}
  .tg input:checked{background:var(--accent);border-color:var(--accent);}
  .tg input:checked::after{content:"";width:7px;height:7px;border-radius:50%;background:#fff;}
  .tg input:checked + span{color:var(--text);}
  .previews{margin-top:26px;}
  .ptabs{display:flex;gap:8px;margin-bottom:10px;}
  .ptab{background:var(--panel2);border:1px solid var(--line);color:var(--muted);
    padding:8px 14px;border-radius:10px;font-size:13px;cursor:pointer;}
  .ptab.active{color:var(--text);border-color:var(--accent);background:rgba(109,94,252,.12);}
  pre{background:var(--code);border:1px solid var(--line);border-radius:12px;padding:16px 18px;
    margin:0;overflow:auto;max-height:340px;font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;
    color:#d5d9e2;white-space:pre;}
  .btn{width:100%;margin-top:14px;background:var(--panel2);border:1px solid var(--line);color:var(--text);
    padding:14px;border-radius:12px;font-size:15px;cursor:pointer;transition:.15s;}
  .btn:hover{border-color:var(--accent);background:rgba(109,94,252,.1);}
  .btn.done{border-color:var(--ok);color:var(--ok);}
  .foot{color:var(--muted);font-size:12.5px;margin-top:16px;}
  .err{color:#ff8080;font-size:13px;margin-top:8px;}
  .nameRow{display:flex;gap:12px;flex-wrap:wrap;margin-top:2px;}
</style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <div class="top">
      <h1>FHIR Profile Designer</h1>
      <span class="pill">Design-time workspace</span>
    </div>

    <div class="profileBox">
      <div class="lbl">Profile</div>
      <div class="nm" id="pfName">New Profile</div>
      <div class="sub"><span id="pfVer">FHIR</span> &middot; Draft &middot; Design-time</div>
    </div>

    <div class="row">
      <div>
        <label class="fld" for="version">FHIR version</label>
        <select id="version"></select>
      </div>
      <div>
        <label class="fld" for="base">Base resource</label>
        <select id="base"></select>
      </div>
    </div>

    <div class="nameRow">
      <div style="flex:1;min-width:200px">
        <label class="fld" for="pname">Profile name</label>
        <input type="text" id="pname" value="LabPatient" placeholder="LabPatient">
      </div>
      <div style="flex:2;min-width:260px">
        <label class="fld" for="curl">Canonical URL</label>
        <input type="text" id="curl" value="https://example.org/fhir/StructureDefinition/LabPatient">
      </div>
    </div>

    <h2>Field constraints</h2>
    <p class="hint">Toggle the elements this profile requires or marks as must-support.</p>
    <div class="constraints" id="constraints"></div>
    <div class="err" id="err"></div>

    <div class="previews">
      <h2>Configuration preview</h2>
      <p class="hint">Copy either output into a FHIR Creator node: the <b>template</b> for mapping, or the <b>profile config</b> for the required-element contract.</p>
      <div class="ptabs">
        <div class="ptab active" data-tab="profile">Profile config</div>
        <div class="ptab" data-tab="template">Resource template</div>
      </div>
      <pre id="preview">{}</pre>
      <button class="btn" id="copyBtn">Copy configuration</button>
    </div>
    <p class="foot">This produces a FHIR differential and a copyable config, not a validated snapshot. Validate the result with the FHIR Validator.</p>
  </div>
</div>

<script>
"use strict";
var API = location.pathname;               // this node's route path
var state = { version:null, base:null, elements:[], required:{}, mustSupport:{},
              template:null, tab:"profile" };

function q(id){ return document.getElementById(id); }
function api(params){
  var u = new URL(API, location.origin);
  Object.keys(params).forEach(function(k){ u.searchParams.set(k, params[k]); });
  return fetch(u.toString(), {headers:{Accept:"application/json"}}).then(function(r){ return r.json(); });
}
function setErr(m){ q("err").textContent = m || ""; }

function profileConfig(){
  var req = state.elements.map(function(e){ return e.path; })
    .filter(function(p){ return state.required[p]; });
  var ms = state.elements.map(function(e){ return e.path; })
    .filter(function(p){ return state.mustSupport[p]; });
  var cfg = {
    resourceType: state.base || "",
    profileName: q("pname").value || "",
    canonicalUrl: q("curl").value || "",
    fhirVersion: state.version || "",
    requiredElements: req
  };
  if (ms.length) cfg.mustSupportElements = ms;
  return cfg;
}

function render(){
  q("pfName").textContent = q("pname").value || "New Profile";
  q("pfVer").textContent = "FHIR " + (state.version || "");
  // constraints
  var host = q("constraints");
  host.innerHTML = "";
  state.elements.forEach(function(e){
    var row = document.createElement("div"); row.className = "crow";
    var left = document.createElement("div");
    left.innerHTML = '<div class="path">'+e.path+'</div>'+
      (e.short ? '<div class="card-note">'+escapeHtml(e.short)+'</div>' : '');
    var right = document.createElement("div"); right.className = "toggles";
    right.appendChild(toggle("Required", state.required[e.path], function(on){ state.required[e.path]=on; refreshPreview(); }));
    right.appendChild(toggle("Must-support", state.mustSupport[e.path], function(on){ state.mustSupport[e.path]=on; refreshPreview(); }));
    row.appendChild(left); row.appendChild(right); host.appendChild(row);
  });
  refreshPreview();
}
function toggle(label, on, onchange){
  var l = document.createElement("label"); l.className = "tg";
  var i = document.createElement("input"); i.type="checkbox"; i.checked=!!on;
  i.addEventListener("change", function(){ onchange(i.checked); });
  var s = document.createElement("span"); s.textContent = label;
  l.appendChild(i); l.appendChild(s); return l;
}
function refreshPreview(){
  q("pfName").textContent = q("pname").value || "New Profile";
  var pre = q("preview");
  if (state.tab === "template"){
    pre.textContent = state.template ? JSON.stringify(state.template, null, 2)
      : "// Select a base resource to load its template.";
  } else {
    pre.textContent = JSON.stringify(profileConfig(), null, 2);
  }
}
function escapeHtml(s){ return String(s).replace(/[&<>]/g, function(c){ return {"&":"&amp;","<":"&lt;",">":"&gt;"}[c]; }); }

function loadBase(){
  setErr("");
  var base = q("base").value;
  state.base = base;
  state.required = {}; state.mustSupport = {}; state.elements = []; state.template = null;
  Promise.all([
    api({action:"elements", base:base, version:state.version}),
    api({resource:base, version:state.version})
  ]).then(function(res){
    var el = res[0], tpl = res[1];
    if (el.error){ setErr(el.error); } else { state.elements = el.elements || []; }
    if (!tpl.error){ state.template = tpl; }
    render();
  }).catch(function(e){ setErr(String(e)); });
}

function loadResources(){
  api({action:"resources", version:state.version}).then(function(d){
    var sel = q("base"); sel.innerHTML = "";
    (d.resources||[]).forEach(function(name){
      var o = document.createElement("option"); o.value=name; o.textContent=name; sel.appendChild(o);
    });
    // default to Patient when present
    if ((d.resources||[]).indexOf("Patient") >= 0) sel.value = "Patient";
    loadBase();
  });
}

function init(){
  api({action:"versions"}).then(function(d){
    var sel = q("version"); sel.innerHTML = "";
    (d.versions||[]).forEach(function(v){
      var o = document.createElement("option"); o.value=v; o.textContent="FHIR "+v; sel.appendChild(o);
    });
    state.version = d.default || (d.versions||[])[0];
    if (state.version) sel.value = state.version;
    loadResources();
  });
  q("version").addEventListener("change", function(){ state.version = q("version").value; loadResources(); });
  q("base").addEventListener("change", loadBase);
  q("pname").addEventListener("input", refreshPreview);
  q("curl").addEventListener("input", refreshPreview);
  Array.prototype.forEach.call(document.querySelectorAll(".ptab"), function(t){
    t.addEventListener("click", function(){
      Array.prototype.forEach.call(document.querySelectorAll(".ptab"), function(x){ x.classList.remove("active"); });
      t.classList.add("active"); state.tab = t.getAttribute("data-tab"); refreshPreview();
    });
  });
  q("copyBtn").addEventListener("click", function(){
    var text = q("preview").textContent;
    navigator.clipboard.writeText(text).then(function(){
      var b = q("copyBtn"); b.classList.add("done"); var old = b.textContent; b.textContent = "Copied";
      setTimeout(function(){ b.classList.remove("done"); b.textContent = old; }, 1400);
    });
  });
}
document.addEventListener("DOMContentLoaded", init);
</script>
</body>
</html>
]==]

-- ---------------------------------------------------------------------------
-- Public: serve a request
-- ---------------------------------------------------------------------------
function M.serve(Portal, Data)
   local Req = linkiir.link.web.request{ data = Data }
   local Location = Req.location or '/'
   local Params = Req.params or {}

   if Location ~= '/' then
      respondError('Unrecognized endpoint: ' .. Location, 404)
      return
   end

   local Action = Params.action

   -- Version list needs no client.
   if Action == 'versions' then
      serveVersions(Portal)
      return
   end

   -- Import parses the body itself and does not depend on a loaded version.
   if Action == 'import' then
      -- Any client will do for importProfile (it is version-agnostic); use the
      -- default so a missing/one-version portal still serves it.
      local Client = clientFor(Portal, Params)
      if not Client then return end
      serveImport(Client, requestBody(Req, Data))
      return
   end

   -- Everything else needs the per-version client.
   if Action == 'resources' then
      local Client = clientFor(Portal, Params); if not Client then return end
      serveResources(Client)
      return
   elseif Action == 'elements' then
      local Client = clientFor(Portal, Params); if not Client then return end
      serveElements(Client, Params)
      return
   elseif Action == 'build' then
      local Client = clientFor(Portal, Params); if not Client then return end
      serveBuild(Client, requestBody(Req, Data))
      return
   elseif Action ~= nil then
      respondError('Unknown action: ' .. tostring(Action), 400)
      return
   end

   -- ?resource=<name>: a JSON resource template (version-aware).
   if Params.resource then
      local Client = clientFor(Portal, Params); if not Client then return end
      serveTemplate(Client, Params)
      return
   end

   -- No action/params: the Profile Designer UI.
   respondHtml(PAGE)
end

return M
