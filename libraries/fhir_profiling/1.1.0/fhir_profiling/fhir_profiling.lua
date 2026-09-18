-- ---------------------------------------------------------------------------
-- fhir_profiling - FHIR resource profiling tool
--
-- Require this module. All other modules are internals.
--
--    local FhirProfiling = require 'fhir_profiling'
--
--    -- Construct once from node config:
--    local Client = FhirProfiling.fromNodeConfig()
--
--    -- Handle an inbound HTTP request:
--    function main(Data)
--       Client:handleRequest(Data)
--    end
--
-- The client loads FHIR specification profiles lazily on first request and
-- caches them in memory. It serves an HTML index of available resources and
-- types at the root path, and returns a JSON template for any resource
-- requested via ?resource=<name>.
-- ---------------------------------------------------------------------------

local newDb         = require 'fhir_profiling_db'
local createResource = require 'fhir_profiling_create'
local Web           = require 'fhir_profiling_web'
local Profile       = require 'fhir_profiling_profile'

-- ---------------------------------------------------------------------------
-- Profile initialisation helpers
-- ---------------------------------------------------------------------------

local function removeCommentsAndDescriptions(Def)
   if not Def.resource or not Def.resource.snapshot then
      return
   end
   local Elements = Def.resource.snapshot.element
   for i = 1, #Elements do
      Elements[i].definition = nil
      Elements[i].comment = nil
   end
end

local function getProfileFileList(VersionPath, CustomPath)
   local List = {}
   List[#List + 1] = VersionPath .. 'types.json'
   List[#List + 1] = VersionPath .. 'resources.json'
   -- Custom profiles
   local CustomFiles = linkiir.sys.fs.list{ path = CustomPath, pattern = '*.json' }
   if CustomFiles then
      for i = 1, #CustomFiles do
         List[#List + 1] = CustomPath .. CustomFiles[i]
      end
   end
   return List
end

local function cleanupAndRewrite(VersionPath)
   local ResourcePath = VersionPath .. 'resources.json'
   local TypePath = VersionPath .. 'types.json'

   local ResourceFile = io.open(ResourcePath, 'r')
   if not ResourceFile then return end
   local ResourceContent = ResourceFile:read('*a')
   ResourceFile:close()

   local TypeFile = io.open(TypePath, 'r')
   if not TypeFile then return end
   local TypeContent = TypeFile:read('*a')
   TypeFile:close()

   local ResourceProfiles = linkiir.json.parse(ResourceContent)
   local TypeProfiles = linkiir.json.parse(TypeContent)

   -- Clean up type profiles
   for i = 1, #TypeProfiles.entry do
      local Entry = TypeProfiles.entry[i]
      Entry.resource.text = nil
      Entry.resource.description = nil
      Entry.resource.contact = nil
      removeCommentsAndDescriptions(Entry)
   end

   -- Clean up resource profiles, removing non-StructureDefinition entries
   local i = 1
   while i <= #ResourceProfiles.entry do
      local Entry = ResourceProfiles.entry[i]
      if Entry.resource.resourceType ~= 'StructureDefinition' then
         table.remove(ResourceProfiles.entry, i)
      else
         Entry.resource.text = nil
         Entry.resource.description = nil
         Entry.resource.contact = nil
         removeCommentsAndDescriptions(Entry)
         i = i + 1
      end
   end

   -- Write cleaned files
   local f = io.open(ResourcePath, 'w')
   if f then f:write(linkiir.json.serialize(ResourceProfiles)); f:close() end
   f = io.open(TypePath, 'w')
   if f then f:write(linkiir.json.serialize(TypeProfiles)); f:close() end
end

local function initializeDb(Db, ProfileFileList)
   if not Db:isInitialized() then
      Db:dropTables()
      for i = 1, #ProfileFileList do
         local File = io.open(ProfileFileList[i], 'r')
         if File then
            local Content = File:read('*a')
            File:close()
            local ProfileJson = linkiir.json.parse(Content)
            Db:init(ProfileJson)
         end
      end
      Db:setIsInitialized(true)
   end
end

-- ---------------------------------------------------------------------------
-- Client object
-- ---------------------------------------------------------------------------

local MT = {}
MT.__index = MT

function MT:ensureLoaded()
   if self.loaded then
      return
   end
   linkiir.log.info('Loading FHIR ' .. self.version .. ' specifications...')

   if self.refresh then
      linkiir.log.info('Refreshing profile database...')
      cleanupAndRewrite(self.version_path)
      self.db:setIsInitialized(false)
   end

   local ProfileFileList = getProfileFileList(self.version_path, self.custom_path)
   initializeDb(self.db, ProfileFileList)

   -- Build the resource and type lists
   local ResourceNames = self.db:listResourceNames('resource')
   local TypeNames = self.db:listResourceNames('complex-type')
   table.sort(ResourceNames)
   table.sort(TypeNames)

   self.resource_lookup = {}
   for i = 1, #ResourceNames do
      self.resource_lookup[ResourceNames[i]:lower()] = ResourceNames[i]
   end
   self.type_lookup = {}
   for i = 1, #TypeNames do
      self.type_lookup[TypeNames[i]:lower()] = TypeNames[i]
   end
   self.sorted_resources = ResourceNames
   self.sorted_types = TypeNames

   self.loaded = true
   linkiir.log.info('FHIR resources loaded and ready.')
end

function MT:sortedList()
   self:ensureLoaded()
   return {
      Resources = self.sorted_resources,
      Types     = self.sorted_types,
   }
end

function MT:resolveResourceName(Query)
   self:ensureLoaded()
   local Lower = Query:lower()
   return self.resource_lookup[Lower] or self.type_lookup[Lower]
end

function MT:createResource(ResourceName)
   self:ensureLoaded()
   return createResource(self, ResourceName)
end

-- 1.1.0: profile authoring. The elements a base resource offers to constrain.
function MT:baseElements(BaseResource)
   return Profile.baseElements(self, BaseResource)
end

-- 1.1.0: compile a constraint spec into a differential StructureDefinition.
function MT:buildProfile(Spec)
   self:ensureLoaded()
   return Profile.buildProfile(self, Spec)
end

-- 1.1.0: parse an imported StructureDefinition, preserving it whole.
function MT:importProfile(Json)
   return Profile.importProfile(Json)
end

-- Portal-compatibility shims: the web layer serves a Portal, but a single
-- Client can still serve itself as a one-version portal (programmatic use and
-- backward compatibility with callers that hold a Client).
function MT:defaultVersion()
   return self.version
end

function MT:versions()
   return { self.version }
end

function MT:client(Version)
   if Version == nil or Version == self.version then
      return self
   end
   return nil, {
      code    = 'CONFIG_ERROR',
      message = 'this client only serves FHIR ' .. tostring(self.version),
   }
end

function MT:handleRequest(Data)
   self:ensureLoaded()
   Web.serve(self, Data)
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {}

-- The FHIR versions this node ships definitions for, and the folder each one
-- lives in under the definitions directory. The folder name is the HL7 release
-- label (e.g. R4_4.0.1) rather than a derived 'v4_0_1', so the on-disk layout
-- reads the way the releases are actually named.
local VERSION_FOLDERS = {
   ['4.0.1'] = 'R4_4.0.1',
   ['5.0.0'] = 'R5_5.0.0',
}

-- The version strings offered in the UI, newest release first.
M.SUPPORTED_VERSIONS = { '5.0.0', '4.0.1' }

function M.versionFolder(Version)
   return VERSION_FOLDERS[Version]
end

-- Construct a client from explicit parameters.
--
-- Options:
--   version      - FHIR version string, e.g. "4.0.1" or "5.0.0"
--   refresh      - boolean, if true the profile DB is rebuilt on first load
--   spec_path    - absolute path to the fhir-definitions directory that holds
--                  one subfolder per release (R4_4.0.1/, R5_5.0.0/)
function M.new(Options)
   local Version = Options.version or '4.0.1'
   local VersionFolder = VERSION_FOLDERS[Version]
   if not VersionFolder then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'Unsupported FHIR version ' .. tostring(Version)
            .. '. Supported: ' .. table.concat(M.SUPPORTED_VERSIONS, ', '),
      }
   end

   local SpecPath = Options.spec_path
   if not SpecPath:match('/$') then
      SpecPath = SpecPath .. '/'
   end

   -- Each release is self-contained in its own folder, including the SQLite
   -- database built from its definitions. That keeps a version switch from
   -- reusing another release's cached profiles, and lets the DB be rebuilt
   -- for one release without touching the others.
   local VersionPath = SpecPath .. VersionFolder .. '/'
   local CustomPath = VersionPath .. 'Custom/'
   local DbPath = VersionPath .. 'fhir_profiles.db'

   -- Ensure custom directory exists
   if not linkiir.sys.fs.access{ path = CustomPath } then
      linkiir.sys.fs.mkdir(CustomPath)
   end

   -- Verify version directory exists
   if not linkiir.sys.fs.access{ path = VersionPath } then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'FHIR version ' .. Version .. ' not available at ' .. VersionPath,
      }
   end

   local Client = setmetatable({
      version      = Version,
      refresh      = Options.refresh or false,
      spec_path    = SpecPath,
      version_path = VersionPath,
      custom_path  = CustomPath,
      db           = newDb(DbPath),
      loaded       = false,
   }, MT)

   return Client
end

-- Construct a client from the node configuration fields.
function M.fromNodeConfig()
   local Config = linkiir.config.node()

   local Version = Config['FHIR Version'] or '4.0.1'
   local Refresh = Config['Refresh']
   if Refresh == 'true' then Refresh = true end
   if Refresh == 'false' then Refresh = false end

   local SpecPath = Config['Specifications Path']
   if not SpecPath or SpecPath == '' then
      -- The definition data ships inside the node under fhir-definitions/, one
      -- folder per release (R4_4.0.1/, R5_5.0.0/), each holding resources.json
      -- and types.json. The per-release SQLite database is built here on first
      -- use rather than shipped. An operator can still point Specifications
      -- Path at an external fhir-definitions directory to override it.
      SpecPath = linkiir.sys.nodeDir() .. '/fhir-definitions/'
   end

   return M.new{
      version   = Version,
      refresh   = Refresh,
      spec_path = SpecPath,
   }
end

-- ---------------------------------------------------------------------------
-- Multi-version portal
--
-- The served UI lets a user switch FHIR version at request time, so the node
-- needs more than the single-version Client that fromNodeConfig builds. The
-- Portal holds the shared configuration (definitions path, refresh flag,
-- default version) and lazily builds and caches one Client per version the
-- first time that version is asked for. Each version's profiles load - and its
-- SQLite database is built - only when someone actually selects it, so the
-- node starts fast and pays the load cost per version on demand.
-- ---------------------------------------------------------------------------

local PortalMT = {}
PortalMT.__index = PortalMT

-- The Client for a given version, built and cached on first use. Returns
-- nil plus an error table when the version is unsupported or its data is
-- missing (M.new validates both).
function PortalMT:client(Version)
   Version = Version or self.default_version
   local Cached = self.clients[Version]
   if Cached then
      return Cached
   end
   local Client, Err = M.new{
      version   = Version,
      refresh   = self.refresh,
      spec_path = self.spec_path,
   }
   if not Client then
      return nil, Err
   end
   self.clients[Version] = Client
   return Client
end

function PortalMT:defaultVersion()
   return self.default_version
end

-- The versions this portal can serve, in UI order. Only those whose data
-- folder is actually present are offered, so a build that ships one release
-- does not advertise another.
function PortalMT:versions()
   local Out = {}
   for _, V in ipairs(M.SUPPORTED_VERSIONS) do
      local Folder = M.versionFolder(V)
      if Folder and linkiir.sys.fs.access{ path = self.spec_path .. Folder .. '/' } then
         Out[#Out + 1] = V
      end
   end
   return Out
end

-- Route an inbound web request. The web layer reads the requested version from
-- the request and resolves the matching Client itself.
function PortalMT:handleRequest(Data)
   Web.serve(self, Data)
end

-- Build a multi-version portal from the node configuration fields. This is
-- what main.lua uses; the single-version fromNodeConfig/Client remain for
-- programmatic use from a workflow.
function M.portalFromNodeConfig()
   local Config = linkiir.config.node()

   local Default = Config['FHIR Version'] or '4.0.1'
   local Refresh = Config['Refresh']
   if Refresh == 'true' then Refresh = true end
   if Refresh == 'false' then Refresh = false end

   local SpecPath = Config['Specifications Path']
   if not SpecPath or SpecPath == '' then
      SpecPath = linkiir.sys.nodeDir() .. '/fhir-definitions/'
   end
   if not SpecPath:match('/$') then
      SpecPath = SpecPath .. '/'
   end

   return setmetatable({
      spec_path       = SpecPath,
      refresh         = Refresh,
      default_version = Default,
      clients         = {},
   }, PortalMT)
end

return M
