-- ---------------------------------------------------------------------------
-- fhir_profiling_db - SQLite storage for FHIR profiles
--
-- Internal module. Provides a database interface for storing and querying
-- FHIR StructureDefinition profiles keyed by resource name and kind.
-- ---------------------------------------------------------------------------

local INIT_SQL = {
   [[CREATE TABLE IF NOT EXISTS Profiles(
      ResourceName TEXT PRIMARY KEY,
      Type TEXT,
      ProfileJson TEXT
   );]],
   [[CREATE TABLE IF NOT EXISTS ProfileTypes(
      ResourceName TEXT PRIMARY KEY,
      Type TEXT
   );]],
   [[CREATE TABLE IF NOT EXISTS State(
      This INTEGER PRIMARY KEY DEFAULT 1,
      IsInitialized BOOLEAN
   );]],
}

local DROP_SQL = {
   [[DROP TABLE IF EXISTS Profiles;]],
   [[DROP TABLE IF EXISTS ProfileTypes;]],
}

-- ---------------------------------------------------------------------------
-- Database interface
-- ---------------------------------------------------------------------------

local function newDb(DbPath)
   local Connection

   local function getConnection()
      if Connection == nil or (Connection.check and Connection:check() == false) then
         Connection = linkiir.store.open{
            driver = linkiir.store.SQLITE,
            name = DbPath,
         }
      end
      return Connection
   end

   local function closeConnection()
      if Connection then
         Connection:close()
         Connection = nil
      end
   end

   local Interface = {}
   local Methods = {}
   setmetatable(Interface, { __index = Methods })

   function Methods:isInitialized()
      local Conn = getConnection()
      local Sql = [[SELECT IsInitialized FROM State WHERE This=1;]]
      local Result, Err = Conn:query{ sql = Sql }
      closeConnection()
      if not Result then
         return false
      end
      if Result:count() == 0 then
         return false
      end
      local Val = Result[1].IsInitialized:value()
      return Val == '1'
   end

   function Methods:setIsInitialized(State)
      local Conn = getConnection()
      local StateVal = State and 1 or 0
      local Sql = [[INSERT OR REPLACE INTO State (This, IsInitialized) VALUES(1, ]]
         .. StateVal .. [[);]]
      Conn:execute{ sql = Sql }
      closeConnection()
   end

   function Methods:dropTables()
      local Conn = getConnection()
      for i = 1, #DROP_SQL do
         Conn:execute{ sql = DROP_SQL[i] }
      end
      closeConnection()
   end

   function Methods:init(Profiles)
      local Conn = getConnection()
      for i = 1, #INIT_SQL do
         Conn:execute{ sql = INIT_SQL[i] }
      end
      for i = 1, #Profiles.entry do
         local Entry = Profiles.entry[i]
         local ResourceName = Entry.resource.id
         if not ResourceName then
            ResourceName = (Entry.resource.title or ''):gsub(' ', '')
         end
         local ProfileJson = linkiir.json.serialize(Entry.resource)
         local EntryType = Entry.resource.kind

         local InsertProfile = [[INSERT OR REPLACE INTO Profiles(ResourceName, Type, ProfileJson) VALUES(]]
            .. Conn:quote(ResourceName) .. [[, ]]
            .. Conn:quote(EntryType) .. [[, ]]
            .. Conn:quote(ProfileJson) .. [[);]]
         Conn:execute{ sql = InsertProfile }

         local InsertKey = [[INSERT OR REPLACE INTO ProfileTypes(ResourceName, Type) VALUES(]]
            .. Conn:quote(ResourceName) .. [[, ]]
            .. Conn:quote(EntryType) .. [[);]]
         Conn:execute{ sql = InsertKey }
      end
      closeConnection()
   end

   function Methods:get(ResourceName)
      local Conn = getConnection()
      local Sql = [[SELECT ProfileJson FROM Profiles WHERE ResourceName=]]
         .. Conn:quote(ResourceName) .. [[;]]
      local Result, Err = Conn:query{ sql = Sql }
      closeConnection()
      if not Result or Result:count() == 0 then
         return nil
      end
      local JsonStr = Result[1].ProfileJson:value()
      return linkiir.json.parse(JsonStr)
   end

   function Methods:listResourceNames(TypeSpec)
      local Conn = getConnection()
      local Sql = [[SELECT ResourceName FROM ProfileTypes]]
      if TypeSpec then
         Sql = Sql .. [[ WHERE Type=]] .. Conn:quote(TypeSpec)
      end
      Sql = Sql .. [[;]]
      local Result, Err = Conn:query{ sql = Sql }
      closeConnection()
      if not Result then
         return {}
      end
      local List = {}
      for i = 1, Result:count() do
         List[#List + 1] = Result[i].ResourceName:value()
      end
      return List
   end

   function Methods:listResourceTypes(TypeSpec)
      local Conn = getConnection()
      local Sql = [[SELECT DISTINCT Type FROM ProfileTypes]]
      if TypeSpec then
         Sql = Sql .. [[ WHERE ResourceName=]] .. Conn:quote(TypeSpec)
      end
      Sql = Sql .. [[;]]
      local Result, Err = Conn:query{ sql = Sql }
      closeConnection()
      if not Result then
         return {}
      end
      local List = {}
      for i = 1, Result:count() do
         List[#List + 1] = Result[i].Type:value()
      end
      return List
   end

   return Interface
end

return newDb
