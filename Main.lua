scriptTitle = "Title Update Manager"
scriptAuthor = "Swizzy, EccentricVamp, Yirr777, FDH & Dan Marti"
scriptVersion = 2
scriptDescription = "Temporary fix for Aurora 0.7b2 and earlier: browse your installed games, download their Title Updates from XboxUnity, or update all of them at once to their latest Title Update. Also lets you enable/disable/mass-apply cached title updates, and free HDD space from title updates belonging to games you no longer have installed. Works around the broken native TU hash check."
scriptIcon = "icon.png"
scriptPermissions = { "http", "filesystem", "content", "sql" }

require("MenuSystem");
local JSON = require("JSON");

-- Aurora's Http.Get can return the response body with leftover buffer bytes
-- appended after the actual content (e.g. {"md5":...}<garbage>). The JSON parser
-- still parses the valid leading value correctly, so tolerate the trailing
-- garbage instead of erroring out on it.
function JSON:onTrailingGarbage(json_text, location, parsed_value, etc)
	return parsed_value;
end

local API_BASE = "http://xboxunity.net/api";

local games = {};
local downloadsRel = "Downloads\\";

-- Sentinel identifying the "update all" main menu entry (distinct from any
-- game table, compared by reference). The leading "--" sorts it above game
-- names under the menu's default alphabetical ordering.
local UPDATE_ALL_MARKER = {};
local UPDATE_ALL_LABEL = "-- Update ALL Games (Latest Only) --";

-- Ported from the standalone "Title Update Enabler" script (by FDH), folded in
-- here as a submenu so both tools live in a single script.
local MANAGE_TU_MARKER = {};
local MANAGE_TU_LABEL = "-- Manage Cached Title Updates --";

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Mirror Aurora's FormatFileSize so the stored FileSize string matches native.
local function FormatSize(bytes)
	bytes = tonumber(bytes) or 0;
	if bytes < 1024 then
		return string.format("%d B", bytes);
	elseif bytes < 1048576 then
		return string.format("%.1f KB", bytes / 1024);
	elseif bytes < 1073741824 then
		return string.format("%.1f MB", bytes / 1048576);
	end
	return string.format("%.1f GB", bytes / 1073741824);
end

-- Escape a Lua string for use inside a single-quoted SQLite literal.
local function SqlStr(s)
	return "'" .. tostring(s):gsub("'", "''") .. "'";
end

-- Store a DWORD the same way Aurora's BindInt does (signed 32-bit), so the
-- value round-trips identically to a native title update entry.
local function Int32(n)
	n = (tonumber(n) or 0) % 4294967296;
	if n >= 2147483648 then
		n = n - 4294967296;
	end
	return string.format("%d", n);
end

-- LivePath as Aurora stores it: filename starting "TU_" -> cache, else content.
local function LivePathFor(titleId, filename)
	if string.sub(filename, 1, 3) == "TU_" then
		return "\\Cache\\";
	end
	return string.format("\\Content\\0000000000000000\\%08X\\000B0000\\", titleId);
end

local function PromptContentDrive()
	local drives = FileSystem.GetDrives(true); -- content-capable drives only
	local names = {};
	for i, d in ipairs(drives) do
		local label = d.MountPoint;
		if d.Name ~= nil and d.Name ~= "" then
			label = label .. "  (" .. d.Name .. ")";
		end
		names[i] = label;
	end
	local pick = Script.ShowPopupList("Select the drive to install to", "No content drives found", names);
	if pick.Canceled then
		return nil;
	end
	return drives[pick.Selected.Key];
end

local function HttpJson(url)
	local ret = Http.Get(url);
	if ret ~= nil and ret.Success == true then
		return JSON:decode(ret.OutputData);
	end
	return nil;
end

local function HashesMatch(a, b)
	return a ~= nil and b ~= nil and string.lower(a) == string.lower(b);
end

-- Set of TU hashes already registered in Aurora's database for a title.
local function GetInstalledHashes(titleId)
	local set = {};
	local rows = Sql.ExecuteFetchRows("SELECT Hash FROM TitleUpdates WHERE TitleId = " .. Int32(titleId));
	if type(rows) == "table" then
		for _, row in ipairs(rows) do
			if row.Hash ~= nil then
				set[string.lower(row.Hash)] = true;
			end
		end
	end
	return set;
end

-- Highest-numbered title update in a list, i.e. the most recent version.
local function GetLatestTU(tus)
	local latest = nil;
	local latestVersion = -1;
	for _, tu in ipairs(tus) do
		local v = tonumber(tu.version) or 0;
		if v > latestVersion then
			latestVersion = v;
			latest = tu;
		end
	end
	return latest;
end

-- ---------------------------------------------------------------------------
-- Install flow
-- ---------------------------------------------------------------------------

-- opts (optional): { drive = <pre-selected drive, skips the drive prompt>,
--                     silent = <true to skip the Yes/No confirm and the final
--                               restart prompt, used by the "update all" flow> }
-- Returns true on success, or false plus a short reason string on failure/cancel.
function HandleTitleUpdate(game, tu, opts)
	opts = opts or {};

	if not opts.silent then
		local info = "Game: " .. game.Name .. "\n";
		info = info .. "Title Update: " .. tostring(tu.version) .. "\n";
		info = info .. "Size: " .. FormatSize(tu.filesize) .. "\n";
		info = info .. "File: " .. tostring(tu.filename) .. "\n\n";
		info = info .. "Download, verify and install this title update?";
		local confirm = Script.ShowMessageBox("Title Update", info, "Yes", "No");
		if confirm.Button ~= 1 then
			return false, "canceled";
		end
	end

	local drive = opts.drive;
	if drive == nil then
		drive = PromptContentDrive();
		if drive == nil then
			return false, "no drive selected";
		end
	end

	-- Cache title updates can't live on USB storage (matches native behaviour).
	local isCacheTU = string.sub(tu.filename, 1, 3) == "TU_";
	if isCacheTU and string.find(string.lower(drive.MountPoint), "usb") == 1 then
		if not opts.silent then
			Script.ShowMessageBox("ERROR", "Cache title updates cannot be installed to a USB drive.\n\nPlease choose an internal (HDD) drive.", "OK");
		end
		return false, "cache TU cannot install to a USB drive";
	end

	-- Resolve paths up front. Like native, we only write the backup copy here;
	-- Aurora copies it to the live location (LivePath) when the TU is activated.
	local livePath = LivePathFor(game.TitleId, tu.filename);          -- stored in DB only
	local backupDir = string.format("Game:\\Data\\TitleUpdates\\%s\\%08X\\%s\\", drive.Serial, game.TitleId, tu.tuhash);
	local backupFile = backupDir .. tu.filename;

	-- The expected whole-file MD5 (same value as the X-Content-MD5 header, which
	-- Lua can't read). Used to verify both an existing backup and a fresh download.
	Script.SetStatus("Checking title update...");
	Script.SetProgress(10);
	local meta = HttpJson(API_BASE .. "/tumd5/" .. tostring(tu.TitleUpdateID));
	if meta == nil or meta.md5 == nil then
		if not opts.silent then
			Script.ShowMessageBox("ERROR", "Could not retrieve the verification hash from the server.\n\nPlease try again later.", "OK");
		end
		return false, "could not retrieve verification hash";
	end

	-- Reuse the backup copy if this exact version is already there and valid;
	-- otherwise download it (backups are per-hash, so versions never collide).
	FileSystem.CreateDirectory(backupDir);
	if not (FileSystem.FileExists(backupFile) and HashesMatch(Aurora.Md5HashFile(backupFile), meta.md5)) then
		Script.CreateDirectory("Downloads");
		local relPath = downloadsRel .. tu.filename;
		Script.SetStatus("Downloading " .. tu.filename .. "...");
		Script.SetProgress(20);
		local dl = Http.Get(tu.url, relPath);
		if dl == nil or dl.Success ~= true then
			if not opts.silent then
				Script.ShowMessageBox("ERROR", "The title update could not be downloaded.\n\nPlease try again later.", "OK");
			end
			FileSystem.DeleteDirectory(Script.GetBasePath() .. downloadsRel);
			return false, "download failed";
		end

		Script.SetStatus("Verifying download...");
		Script.SetProgress(70);
		local got = Aurora.Md5HashFile(dl.OutputPath);
		if not HashesMatch(got, meta.md5) then
			print("TUDownloader: MD5 mismatch got(" .. tostring(got) .. ") expected(" .. tostring(meta.md5) .. ")");
			Script.SetStatus("Verification failed!");
			Script.SetProgress(0);
			if not opts.silent then
				Script.ShowMessageBox("Verification failed", "The downloaded title update's hash did not match the server.\n\nThe file was discarded.", "OK");
			end
			FileSystem.DeleteDirectory(Script.GetBasePath() .. downloadsRel);
			return false, "hash verification failed";
		end

		-- Verified: move it into its per-hash backup folder (overwrite any partial).
		if FileSystem.MoveFile(dl.OutputPath, backupFile, true) ~= true then
			if not opts.silent then
				Script.ShowMessageBox("ERROR", "The title update was verified but could not be saved to:\n" .. backupFile, "OK");
			end
			FileSystem.DeleteDirectory(Script.GetBasePath() .. downloadsRel);
			return false, "could not save backup file";
		end
		FileSystem.DeleteDirectory(Script.GetBasePath() .. downloadsRel);
	end

	-- Register it in Aurora's database (same row a native download writes), unless
	-- this exact version is already registered for this drive.
	Script.SetStatus("Adding to database...");
	Script.SetProgress(90);
	local exists = Sql.ExecuteFetchRows(string.format(
		"SELECT Id FROM TitleUpdates WHERE TitleId = %s AND Hash = %s AND LiveDeviceId = %s",
		Int32(game.TitleId), SqlStr(tu.tuhash), SqlStr(drive.Serial)));
	local alreadyRegistered = (type(exists) == "table" and #exists > 0);

	if not alreadyRegistered then
		local insert = "INSERT INTO TitleUpdates (FileName, LiveDeviceId, LivePath, TitleId, Version, Hash, BackupPath, BaseVersion, DisplayName, MediaId, FileSize) VALUES ("
			.. SqlStr(tu.filename) .. ", "
			.. SqlStr(drive.Serial) .. ", "
			.. SqlStr(livePath) .. ", "
			.. Int32(game.TitleId) .. ", "
			.. Int32(tu.version) .. ", "
			.. SqlStr(tu.tuhash) .. ", "
			.. SqlStr(backupFile) .. ", "
			.. Int32(game.BaseVersion) .. ", "
			.. SqlStr(game.Name) .. ", "
			.. Int32(game.MediaId) .. ", "
			.. SqlStr(FormatSize(tu.filesize)) .. ")";
		if Sql.Execute(insert) ~= true then
			if not opts.silent then
				Script.ShowMessageBox("ERROR", "The title update was installed but could not be added to Aurora's database.", "OK");
			end
			return false, "could not add to database";
		end
	end

	Script.SetStatus("Done!");
	Script.SetProgress(100);

	if opts.silent then
		return true;
	end

	local msg;
	if alreadyRegistered then
		msg = "Title update verified and already in Aurora's database.";
	else
		msg = "Title update verified and added to Aurora's database.";
	end
	local restart = Script.ShowMessageBox("Success", msg .. "\n\nRestart Aurora to load it, then enable it from the game's Title Updates menu. Restart now?", "Yes", "No");
	if restart.Button == 1 then
		Aurora.Restart();
	end
	return true;
end

function HandleGame(game)
	local listUrl = string.format("%s/tu/%08X/%08X", API_BASE, game.TitleId, game.BaseVersion);
	Script.SetStatus("Fetching title updates for " .. game.Name .. "...");
	Script.SetProgress(0);

	local tus = HttpJson(listUrl);
	if type(tus) ~= "table" or #tus == 0 then
		Script.ShowMessageBox(game.Name, "No title updates were found for this game on XboxUnity.", "OK");
		return;
	end

	local installed = GetInstalledHashes(game.TitleId);
	local display = {};
	for i, tu in ipairs(tus) do
		local mark = "";
		if tu.tuhash ~= nil and installed[string.lower(tu.tuhash)] then
			mark = "√ ";
		end
		display[i] = mark .. "Title Update " .. tostring(tu.version) .. "   (" .. FormatSize(tu.filesize) .. ")";
	end

	local pick = Script.ShowPopupList("Title Updates - " .. game.Name, "No title updates found", display);
	if pick.Canceled then
		return;
	end
	HandleTitleUpdate(game, tus[pick.Selected.Key]);
end

-- ---------------------------------------------------------------------------
-- Update-all flow
-- ---------------------------------------------------------------------------

-- Looks up every game's latest title update and returns the ones that aren't
-- already installed, as a list of { game = <game>, tu = <latest tu> }.
local function BuildUpdatePlan()
	local plan = {};
	local total = #games;
	for i, game in ipairs(games) do
		Script.SetStatus(string.format("Analyzing %d/%d: %s...", i, total, game.Name));
		Script.SetProgress(math.floor((i - 1) / total * 100));

		local listUrl = string.format("%s/tu/%08X/%08X", API_BASE, game.TitleId, game.BaseVersion);
		local tus = HttpJson(listUrl);
		if type(tus) == "table" and #tus > 0 then
			local latest = GetLatestTU(tus);
			if latest ~= nil and latest.tuhash ~= nil then
				local installed = GetInstalledHashes(game.TitleId);
				if not installed[string.lower(latest.tuhash)] then
					table.insert(plan, { game = game, tu = latest });
				end
			end
		end
	end
	return plan;
end

function HandleUpdateAll()
	Script.SetStatus("Analyzing your games...");
	Script.SetProgress(0);
	local plan = BuildUpdatePlan();

	if #plan == 0 then
		Script.ShowMessageBox("Update All Games", "All your games already have the latest title update installed (or none have any title updates available).", "OK");
		return;
	end

	-- Single confirmation up front with a summary, so the whole batch runs
	-- without a popup per game.
	local totalSize = 0;
	local lines = {};
	for _, item in ipairs(plan) do
		totalSize = totalSize + (tonumber(item.tu.filesize) or 0);
		table.insert(lines, string.format("- %s (v%s, %s)", item.game.Name, tostring(item.tu.version), FormatSize(item.tu.filesize)));
	end

	local summary = string.format("Found %d title update(s) to install:\n\n", #plan);
	local maxLines = 10;
	for i, line in ipairs(lines) do
		if i > maxLines then
			summary = summary .. string.format("...and %d more\n", #lines - maxLines);
			break;
		end
		summary = summary .. line .. "\n";
	end
	summary = summary .. "\nTotal download size: " .. FormatSize(totalSize) .. "\n\nDownload, verify and install all of these now?";

	local confirm = Script.ShowMessageBox("Update All Games", summary, "Yes", "No");
	if confirm.Button ~= 1 then
		return;
	end

	local drive = PromptContentDrive();
	if drive == nil then
		return;
	end

	local installedCount = 0;
	local failed = {};
	local total = #plan;
	for i, item in ipairs(plan) do
		Script.SetStatus(string.format("Installing %d/%d: %s...", i, total, item.game.Name));
		Script.SetProgress(math.floor((i - 1) / total * 100));

		local ok, reason = HandleTitleUpdate(item.game, item.tu, { drive = drive, silent = true });
		if ok then
			installedCount = installedCount + 1;
		else
			table.insert(failed, item.game.Name .. (reason ~= nil and (" (" .. reason .. ")") or ""));
		end
	end

	Script.SetStatus("Done!");
	Script.SetProgress(100);

	local result = string.format("Installed %d of %d title update(s).", installedCount, total);
	if #failed > 0 then
		result = result .. "\n\nFailed:\n";
		for _, name in ipairs(failed) do
			result = result .. "- " .. name .. "\n";
		end
	end

	if installedCount > 0 then
		result = result .. "\nRestart Aurora to load the new title update(s), then enable them from each game's Title Updates menu. Restart now?";
		local restart = Script.ShowMessageBox("Update All Games - Done", result, "Yes", "No");
		if restart.Button == 1 then
			Aurora.Restart();
		end
	else
		Script.ShowMessageBox("Update All Games - Done", result, "OK");
	end
end

-- ---------------------------------------------------------------------------
-- Manage cached title updates (ported from "Title Update Enabler" by FDH)
-- ---------------------------------------------------------------------------

-- Marks the highest-Version TitleUpdates row per TitleId as active.
function EnableAllTitleUpdates()
	local countResult = Sql.ExecuteFetchRows("SELECT COUNT(*) as Count FROM TitleUpdates");
	local totalTitleUpdates = countResult[1].Count;

	if totalTitleUpdates == 0 then
		Script.ShowMessageBox("No Title Updates", "No title updates found in database.", "OK");
		return;
	end

	Sql.Execute("DELETE FROM ActiveTitleUpdates");

	-- Assumes higher `Version` = newer version for the same title.
	Sql.Execute([[
		INSERT INTO ActiveTitleUpdates (TitleUpdateId)
		SELECT Id FROM TitleUpdates t1
		WHERE Version = (
			SELECT MAX(Version) FROM TitleUpdates t2
			WHERE t1.TitleId = t2.TitleId
		)
	]]);

	local enabledResult = Sql.ExecuteFetchRows("SELECT COUNT(*) as Count FROM ActiveTitleUpdates");
	local enabledCount = enabledResult[1].Count;

	if enabledCount >= 1 then
		local ret = Script.ShowMessageBox("Title Updates Enabled", "Successfully enabled " .. enabledCount .. " (" .. totalTitleUpdates .. " total) latest title updates.\n\nRestart Aurora for the changes to take effect. Restart now?", "Yes", "No");
		if ret.Button == 1 then
			Aurora.Restart();
		end
	else
		Script.ShowMessageBox("Title Updates Enabled", "Enabled " .. enabledCount .. " of " .. totalTitleUpdates .. " title updates.", "OK");
	end
end

-- Clears ActiveTitleUpdates, deactivating every currently-enabled title update.
function DisableAllTitleUpdates()
	local countResult = Sql.ExecuteFetchRows("SELECT COUNT(*) as Count FROM ActiveTitleUpdates");
	local disabledCount = countResult[1].Count;

	Sql.Execute("DELETE FROM ActiveTitleUpdates");

	local ret = Script.ShowMessageBox("Title Updates Disabled", disabledCount .. " title update(s) have been disabled.\n\nRestart Aurora for the changes to take effect. Restart now?", "Yes", "No");
	if ret.Button == 1 then
		Aurora.Restart();
	end
end

-- Permanently moves every active title update from its Aurora backup path to
-- its live location, then removes it from Aurora's database. Irreversible:
-- once applied, Aurora no longer manages that title update.
function InstallAllTitleUpdates()
	local ret = Script.ShowMessageBox("Are you sure?", "This will permanently apply the currently enabled title updates, moving them out of Aurora's managed cache.\n\nIf you want Aurora to keep managing title updates, you probably shouldn't do this!\n\nAre you sure you want to continue?", "No", "Yes");
	if ret.Button ~= 2 then
		return;
	end

	local activeTitleUpdates = Sql.ExecuteFetchRows([[
		SELECT tu.Id, tu.FileName, tu.LiveDeviceId, tu.LivePath, tu.TitleId, tu.BackupPath
		FROM TitleUpdates tu
		INNER JOIN ActiveTitleUpdates atu ON tu.Id = atu.TitleUpdateId
	]]);

	if type(activeTitleUpdates) ~= "table" or #activeTitleUpdates == 0 then
		Script.ShowMessageBox("No Active Title Updates", "No active title updates found to install.", "OK");
		return;
	end

	local matchingDrives = {};
	for _, drive in ipairs(FileSystem.GetDrives(false)) do
		matchingDrives[drive.Serial] = drive.MountPoint;
	end

	local total = #activeTitleUpdates;
	local successes = 0;
	local failures = 0;

	for i, tu in ipairs(activeTitleUpdates) do
		Script.SetStatus("Applying: " .. tu.FileName .. "...");
		Script.SetProgress(math.floor((i - 1) / total * 100));

		local destinationPath = (matchingDrives[tu.LiveDeviceId] or "") .. tu.LivePath .. tu.FileName;
		local success = FileSystem.MoveFile(tu.BackupPath, destinationPath, true);

		if success then
			Sql.Execute("DELETE FROM TitleUpdates WHERE Id = " .. tu.Id);
			Sql.Execute("DELETE FROM ActiveTitleUpdates WHERE TitleUpdateId = " .. tu.Id);
			successes = successes + 1;
		else
			failures = failures + 1;
		end
	end

	Script.SetStatus("Done!");
	Script.SetProgress(100);

	local done = Script.ShowMessageBox("Mass Apply Complete", "Successfully applied: " .. successes .. "\nFailed: " .. failures .. "\nTotal: " .. total .. "\n\nRestart Aurora for the changes to take effect. Restart now?", "Yes", "No");
	if done.Button == 1 then
		Aurora.Restart();
	end
end

-- Finds title updates registered for games that are no longer installed
-- (TitleId missing from ContentItems) and offers to delete their backup and
-- live files, freeing HDD space, then removes them from Aurora's database.
function FreeMyDisk()
	Script.SetStatus("Scanning for unused title updates...");
	Script.SetProgress(0);

	local matchingDrives = {};
	for _, drive in ipairs(FileSystem.GetDrives(false)) do
		matchingDrives[drive.Serial] = drive.MountPoint;
	end

	local rows = Sql.ExecuteFetchRows([[
		SELECT tus.Id AS id, tus.DisplayName AS tu, tus.BackupPath AS backuppath,
		       tus.LiveDeviceId AS livedeviceid, (tus.LivePath || tus.FileName) AS path
		FROM TitleUpdates AS tus
		WHERE tus.TitleId NOT IN (SELECT TitleId FROM ContentItems WHERE TitleId = tus.TitleId)
		AND NOT tus.MediaId = 0
	]]);

	local totalSize = 0;
	local tuIds = {};
	local files = {};
	local summaryLines = {};

	if type(rows) == "table" then
		for _, row in ipairs(rows) do
			-- Fall back to "Hdd1:" if the drive serial isn't currently connected,
			-- matching the original script's assumption.
			local livePath = (matchingDrives[row.livedeviceid] or "Hdd1:") .. row.path;
			local thisSize = 0;

			if FileSystem.FileExists(row.backuppath) then
				table.insert(files, row.backuppath);
				thisSize = thisSize + (tonumber(FileSystem.GetFileSize(row.backuppath)) or 0);
			end
			if FileSystem.FileExists(livePath) then
				table.insert(files, livePath);
				thisSize = thisSize + (tonumber(FileSystem.GetFileSize(livePath)) or 0);
			end

			if thisSize > 0 then
				table.insert(tuIds, row.id);
				table.insert(summaryLines, "- " .. tostring(row.tu) .. " (" .. FormatSize(thisSize) .. ")");
				totalSize = totalSize + thisSize;
			end
		end
	end

	if totalSize == 0 then
		Script.ShowMessageBox("Free My Disk", "Good news! There are no unused title updates taking up space.", "OK");
		return;
	end

	-- Loop mirrors the original script's flow: backing out of the "are you
	-- sure" confirmation returns to the initial removal prompt.
	while true do
		local summary = string.format("Found %d unused title update(s) using %s:\n\n", #tuIds, FormatSize(totalSize));
		local maxLines = 10;
		for i, line in ipairs(summaryLines) do
			if i > maxLines then
				summary = summary .. string.format("...and %d more\n", #summaryLines - maxLines);
				break;
			end
			summary = summary .. line .. "\n";
		end
		summary = summary .. "\nDo you want to remove them?";

		local confirm = Script.ShowMessageBox("Free My Disk", summary, "Yes", "No");
		if confirm.Button ~= 1 then
			return;
		end

		local sure = Script.ShowMessageBox("Free My Disk", "These files will be permanently deleted.\n\nAre you sure you want to continue?", "Yes", "No");
		if sure.Button == 1 then
			break;
		end
	end

	local total = #files;
	local freedSize = 0;
	local errors = 0;

	for i, path in ipairs(files) do
		Script.SetStatus(string.format("Deleting %d/%d...", i, total));
		Script.SetProgress(math.floor((i - 1) / total * 100));
		local size = tonumber(FileSystem.GetFileSize(path)) or 0;
		if FileSystem.DeleteFile(path) == true then
			freedSize = freedSize + size;
		else
			print("FreeMyDisk: failed to delete " .. tostring(path));
			errors = errors + 1;
		end
	end

	for _, id in ipairs(tuIds) do
		if Sql.Execute("DELETE FROM TitleUpdates WHERE Id = " .. tostring(id)) ~= true then
			print("FreeMyDisk: failed to remove TitleUpdates row Id=" .. tostring(id));
			errors = errors + 1;
		end
	end

	Script.SetStatus("Done!");
	Script.SetProgress(100);

	local msg = string.format("Freed %s across %d file(s) from %d title update(s).", FormatSize(freedSize), total, #tuIds);
	if errors > 0 then
		msg = msg .. "\n\nThere were " .. errors .. " error(s), check the log for details.";
	end
	Script.ShowMessageBox("Free My Disk", msg, "OK");
end

function HandleManageTitleUpdates()
	local options = { "Enable Latest Updates", "Disable Latest Updates", "Mass Apply Latest Updates", "Free My Disk (Remove Unused TUs)" };
	local pick = Script.ShowPopupList("Manage Cached Title Updates", "No options available", options);
	if pick.Canceled then
		return;
	end

	if pick.Selected.Key == 1 then
		EnableAllTitleUpdates();
	elseif pick.Selected.Key == 2 then
		DisableAllTitleUpdates();
	elseif pick.Selected.Key == 3 then
		InstallAllTitleUpdates();
	elseif pick.Selected.Key == 4 then
		FreeMyDisk();
	end
end

-- ---------------------------------------------------------------------------
-- Menu / entry point
-- ---------------------------------------------------------------------------

function BuildGamesList()
	local seen = {};
	local collection = Content.FindContent();
	for i = 1, #collection do
		local item = collection[i];
		if item.TitleId ~= nil and item.TitleId ~= 0 then
			local key = string.format("%08X_%08X", item.TitleId, item.BaseVersion);
			if seen[key] == nil then
				seen[key] = true;
				table.insert(games, {
					Name = item.Name,
					TitleId = item.TitleId,
					MediaId = item.MediaId,
					BaseVersion = item.BaseVersion,
				});
			end
		end
	end
	return #games > 0;
end

function MakeMainMenu()
	Menu.ResetMenu();
	Menu.SetTitle(scriptTitle);
	Menu.SetGoBackText("");
	Menu.AddMainMenuItem(Menu.MakeMenuItem(UPDATE_ALL_LABEL, UPDATE_ALL_MARKER));
	Menu.AddMainMenuItem(Menu.MakeMenuItem(MANAGE_TU_LABEL, MANAGE_TU_MARKER));
	for _, game in ipairs(games) do
		Menu.AddMainMenuItem(Menu.MakeMenuItem(game.Name, game));
	end
end

function DoShowMenu()
	local selection, _, canceled = Menu.ShowMainMenu();
	if not canceled then
		if selection == UPDATE_ALL_MARKER then
			HandleUpdateAll();
		elseif selection == MANAGE_TU_MARKER then
			HandleManageTitleUpdates();
		else
			HandleGame(selection);
		end
		DoShowMenu();
	end
end

function main()
	if Aurora.HasInternetConnection() ~= true then
		Script.ShowMessageBox("ERROR", "This script requires an active internet connection.\n\nPlease connect your console to the internet and try again.", "OK");
		return;
	end

	print("-- " .. scriptTitle .. " Started...");
	if BuildGamesList() then
		MakeMainMenu();
		DoShowMenu();
	else
		Script.ShowMessageBox(scriptTitle, "No installed games were found in your library to look up title updates for.", "OK");
	end
	FileSystem.DeleteDirectory(Script.GetBasePath() .. downloadsRel);
	print("-- " .. scriptTitle .. " Ended...");
end
