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

function MT:handleRequest(Data)
   self:ensureLoaded()
   Web.serve(self, Data)
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {}

-- Construct a client from explicit parameters.
--
-- Options:
--   version      - FHIR version string, e.g. "4.0.1"
--   refresh      - boolean, if true the profile DB is rebuilt on first load
--   spec_path    - absolute path to the Specifications directory
function M.new(Options)
   local Version = Options.version or '4.0.1'
   local VersionFolder = 'v' .. Version:gsub('%.', '_') .. '/'

   local SpecPath = Options.spec_path
   if not SpecPath:match('/$') then
      SpecPath = SpecPath .. '/'
   end

   local VersionPath = SpecPath .. VersionFolder
   local CustomPath = SpecPath .. 'Custom/'
   local DbPath = SpecPath .. 'fhir_profiles.db'

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
      SpecPath = linkiir.sys.nodeDir() .. '/Specifications/'
   end

   return M.new{
      version   = Version,
      refresh   = Refresh,
      spec_path = SpecPath,
   }
end

return M
