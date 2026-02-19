--[[
    AI Stem Splitter (Mac Native - Self Contained Environment)
    Professional, Autonomous Audio Separation Engine
    
    Features:
    - Auto-Creates Virtual Environment at ~/.reaper_demucs_env
    - Installs Demucs + Librosa/Numpy/Scipy automatically
    - Synchronizes imported stems with original item position
    - Dynamically imports all generated stems
    - Robust Dependency Verification (Anti-Corruption)
    - Graceful Analysis Fallback
    
    Author: Antigravity (Google Deepmind)
    Version: 4.0 (Robust Self-Contained)
]]

local APP_NAME = "AI Stem Splitter v4.0 (Professional)"
local MODEL_NAME = "htdemucs" -- Defaulting to standard 4-stem model for max compatibility
local ENV_DIR_NAME = ".reaper_demucs_env"

-- GUI Constants
local GUI_W, GUI_H = 600, 350
local STATE_IDLE = 0
local STATE_SETUP_ENV = 1 -- Installing/Creating Venv
local STATE_RUNNING = 2
local STATE_DONE = 3
local STATE_ERROR = 4

local ctx = {
    state = STATE_IDLE,
    status = "Idle",
    log_lines = {},
    work_dir = "",
    home_dir = "",
    venv_python = "", -- The python inside the venv
    system_python = "", -- The python used to create the venv
    runner_path = "",
    log_file_path = "",
    last_log_size = 0,
    item_pos = 0, -- Original item position
    song_name = ""
}

--------------------------------------------------------------------------------
-- 1. UTILS & PATHS
--------------------------------------------------------------------------------

local function file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function get_home_dir()
    return os.getenv("HOME")
end

local function escape_for_bash(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function escape_for_python(s)
    return s:gsub("\\", "\\\\"):gsub("'", "\\'")
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

-- Find a system python just to create the VENV
local function find_system_python()
    local candidates = {
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3"
    }
    for _, path in ipairs(candidates) do
        if file_exists(path) then return path end
    end
    return nil
end

local function get_venv_python_path()
    local home = get_home_dir()
    if not home then return nil end
    return home .. "/" .. ENV_DIR_NAME .. "/bin/python3"
end

local function ensure_work_dir()
    local home = get_home_dir()
    if not home then return nil end
    local path = home .. "/Documents/REAPER_AI_Stems_Temp"
    os.execute("mkdir -p '" .. path .. "'")
    return path
end

-- CRITICAL FIX: Verify libraries actually import
local function verify_venv_libraries(python_path)
    if not file_exists(python_path) then return false end
    
    -- Try to import demucs. If this fails, the env is corrupt or incomplete.
    local cmd = "'" .. python_path .. "' -c \"import demucs; print('ok')\""
    local handle = io.popen(cmd)
    if not handle then return false end
    local output = handle:read("*a")
    handle:close()
    
    return output:match("ok") ~= nil
end

--------------------------------------------------------------------------------
-- 2. ENVIRONMENT SETUP (VENV)
--------------------------------------------------------------------------------

local function generate_setup_script(work_dir, system_python)
    local script_path = work_dir .. "/setup_env.sh"
    local log_path = work_dir .. "/setup_log.txt"
    local done_path = work_dir .. "/setup_done.marker"
    local error_path = work_dir .. "/setup_error.marker"
    local venv_path = get_home_dir() .. "/" .. ENV_DIR_NAME
    
    os.remove(done_path)
    os.remove(error_path)
    write_file(log_path, "")
    
    local script = table.concat({
        "#!/bin/bash",
        "exec > " .. escape_for_bash(log_path) .. " 2>&1",
        "echo \"[Setup] Starting Environment Setup...\"",
        "echo \"[Setup] Target VENV: " .. venv_path .. "\"",
        "",
        -- Force re-creation if verifying libraries failed (which is why we are here)
        "if [ -d \"" .. venv_path .. "\" ]; then",
        "    echo \"[Setup] Existing VENV found but marked as invalid/incomplete.\"",
        "    echo \"[Setup] Removing and recreating...\"",
        "    rm -rf \"" .. venv_path .. "\"",
        "fi",
        "",
        "echo \"[Setup] Creating Virtual Environment using " .. system_python .. "...\"",
        "" .. escape_for_bash(system_python) .. " -m venv \"" .. venv_path .. "\"",
        "if [ $? -ne 0 ]; then",
        "    echo \"[Error] Failed to create VENV.\"",
        "    touch " .. escape_for_bash(error_path),
        "    exit 1",
        "fi",
        "",
        "VENV_PY=\"" .. venv_path .. "/bin/python3\"",
        "echo \"[Setup] Updating pip/setuptools...\"",
        "\"$VENV_PY\" -m pip install -U pip setuptools wheel >/dev/null",
        "",
        "echo \"[Setup] Installing AI Dependencies (demucs, librosa, numpy, scipy)...\"",
        "echo \"[Setup] PLEASE WAIT. This involves downloading ~1GB of model data.\"",
        "\"$VENV_PY\" -m pip install demucs librosa numpy scipy",
        "if [ $? -ne 0 ]; then",
        "    echo \"[Error] Failed to install dependencies.\"",
        "    touch " .. escape_for_bash(error_path),
        "    exit 1",
        "fi",
        "",
        "echo \"[Setup] verifying install...\"",
        "\"$VENV_PY\" -c \"import demucs; print('Demucs installed OK')\"",
        "if [ $? -ne 0 ]; then",
        "    echo \"[Error] Verification failed.\"",
        "    touch " .. escape_for_bash(error_path),
        "    exit 1",
        "fi",
        "",
        "echo \"[Setup] Success! Environment matches requirements.\"",
        "touch " .. escape_for_bash(done_path),
        "exit 0"
    }, "\n")
    
    write_file(script_path, script)
    os.execute("chmod +x " .. escape_for_bash(script_path))
    return script_path, done_path, error_path, log_path
end

--------------------------------------------------------------------------------
-- 3. PROCESSING LOGIC
--------------------------------------------------------------------------------

local function build_analysis_script_content(file_path, output_path, log_path)
    local script = [[
import sys
import os

def run_analysis():
    # Robust Fallback: even if imports fail, we shouldn't crash ungracefully
    try:
        import scipy.signal
        if not hasattr(scipy.signal, 'hann'):
            try: scipy.signal.hann = scipy.signal.windows.hann
            except AttributeError: pass 
        import librosa
        import numpy as np
    except ImportError as e:
        with open(r']] .. escape_for_python(output_path) .. [[', 'w') as f: f.write("||")
        with open(r']] .. escape_for_python(log_path) .. [[', 'a') as f: f.write(f"\n[Analysis Warning] Librosa/Scientific libs missing. Skipping BPM detection. {e}\n")
        return

    input_path = r']] .. escape_for_python(file_path) .. [['
    output_path = r']] .. escape_for_python(output_path) .. [['
    
    try:
        y, sr = librosa.load(input_path, sr=None, duration=60)
        tempo, _ = librosa.beat.beat_track(y=y, sr=sr)
        bpm = int(round(tempo)) if tempo else 0
        
        chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
        chroma_vals = np.sum(chroma, axis=1)
        maj = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
        min_p = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
        
        maj_c = [np.corrcoef(np.roll(maj, i), chroma_vals)[0,1] for i in range(12)]
        min_c = [np.corrcoef(np.roll(min_p, i), chroma_vals)[0,1] for i in range(12)]
        key_n = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B']
        
        key = key_n[np.argmax(maj_c)] if np.max(maj_c) > np.max(min_c) else key_n[np.argmax(min_c)] + "m"
        
        tune = librosa.estimate_tuning(y=y, sr=sr)
        hz = int(round(440 * (2**(tune/12))))
        
        with open(output_path, 'w') as f: f.write(f"{bpm}|{key}|{hz}")
            
    except Exception as e:
        # Fallback: write empty pipe so Lua knows analysis failed but script continues
        with open(output_path, 'w') as f: f.write("||")
        with open(r']] .. escape_for_python(log_path) .. [[', 'a') as f: f.write(f"\n[Analysis Error] {e}\n")

if __name__ == '__main__': run_analysis()
]]
    return script
end

local function generate_run_script(work_dir, venv_python, input_file, log_file)
    local runner_path = work_dir .. "/run_demucs.sh"
    local analysis_py = work_dir .. "/analyze_audio.py"
    local analysis_out = work_dir .. "/analysis_info.txt"
    local done_file = work_dir .. "/run_done.marker"
    local error_file = work_dir .. "/run_error.marker"
    local list_file = work_dir .. "/stems_list.txt"
    
    os.remove(done_file)
    os.remove(error_file)
    os.remove(analysis_out)
    os.remove(list_file)
    write_file(log_file, "") -- Clear run log
    
    write_file(analysis_py, build_analysis_script_content(input_file, analysis_out, log_file))
    
    local script = table.concat({
        "#!/bin/bash",
        "export PYTHONUTF8=1",
        "exec > " .. escape_for_bash(log_file) .. " 2>&1",
        "",
        "VPY=" .. escape_for_bash(venv_python),
        "WORK_DIR=" .. escape_for_bash(work_dir),
        "IN_FILE=" .. escape_for_bash(input_file),
        "MODEL_NAME=\"" .. MODEL_NAME .. "\"",
        "",
        "echo \"[Runner] Analyzing...\"",
        -- We run analysis but dont exit if it fails. We just log it.
        "\"$VPY\" " .. escape_for_bash(analysis_py) .. " || echo \"[Analysis] Script returned error code, continuing to separate...\"",
        "",
        "echo \"[Runner] Separating with $MODEL_NAME...\"",
        "\"$VPY\" -m demucs.separate -n \"$MODEL_NAME\" \"$IN_FILE\" -o \"$WORK_DIR\"",
        "RET=$?",
        "if [ $RET -ne 0 ]; then",
        "    echo \"[Error] Demucs failed code $RET\"",
        "    touch " .. escape_for_bash(error_file),
        "    exit $RET",
        "fi",
        "",
        "echo \"[Runner] Scanning for stems...\"",
        "find \"$WORK_DIR/$MODEL_NAME\" -name \"*.wav\" > " .. escape_for_bash(list_file),
        "",
        "echo \"[Runner] Success.\"",
        "touch " .. escape_for_bash(done_file),
        "exit 0"
    }, "\n")
    
    write_file(runner_path, script)
    os.execute("chmod +x " .. escape_for_bash(runner_path))
    return runner_path, done_file, error_file, analysis_out, list_file
end

--------------------------------------------------------------------------------
-- 4. IMPORT LOGIC
--------------------------------------------------------------------------------

local function parse_analysis(path)
    local c = read_file(path)
    if not c then return nil end
    local b, k, h = c:match("([^|]*)|([^|]*)|([^|]*)")
    if b and k and h and b ~= "" then return {bpm=b, key=k, hz=h} end
    return nil
end

local function import_stems(list_path, analysis, original_pos, song_display_name)
    local content = read_file(list_path)
    if not content then 
        reaper.ShowMessageBox("No stems list generated.", APP_NAME, 0)
        return 
    end
    
    local files = {}
    for line in content:gmatch("[^\r\n]+") do
        if line and line ~= "" then table.insert(files, line) end
    end
    
    if #files == 0 then
        reaper.ShowMessageBox("AI process finished but no audio files were found.\nCheck the log.", APP_NAME, 0)
        return
    end
    
    reaper.PreventUIRefresh(1)
    reaper.Undo_BeginBlock()
    
    local track_idx = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(track_idx, true)
    local folder_tr = reaper.GetTrack(0, track_idx)
    
    local name = "STEMS: " .. song_display_name
    if analysis then
        name = name .. " [" .. analysis.bpm .. "bpm " .. analysis.key .. " @" .. analysis.hz .. "Hz]"
    end
    
    reaper.GetSetMediaTrackInfo_String(folder_tr, "P_NAME", name, true)
    reaper.SetMediaTrackInfo_Value(folder_tr, "I_FOLDERDEPTH", 1)
    
    for _, file_path in ipairs(files) do
        reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
        local tr = reaper.GetTrack(0, reaper.CountTracks(0)-1)
        
        local stem_name = file_path:match("([^/]+)%.wav$") or "stem"
        stem_name = stem_name:gsub("^%l", string.upper)
        
        reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", stem_name, true)
        reaper.SetOnlyTrackSelected(tr)
        reaper.SetEditCurPos(original_pos, false, false)
        
        local success = reaper.InsertMedia(file_path, 0)
        
        if success then
             local mk = reaper.GetTrackMediaItem(tr, 0)
             if mk then
                 reaper.SetMediaItemInfo_Value(mk, "D_POSITION", original_pos)
             end
        end
    end
    
    local last_tr = reaper.GetTrack(0, reaper.CountTracks(0)-1)
    reaper.SetMediaTrackInfo_Value(last_tr, "I_FOLDERDEPTH", -1)
    
    reaper.Undo_EndBlock("Import AI Stems", -1)
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
end

--------------------------------------------------------------------------------
-- 5. GUI & LOOP
--------------------------------------------------------------------------------

local function cleanup()
    -- Attempt to clear markers so next run is clean
    if ctx.done_file then os.remove(ctx.done_file) end
    if ctx.error_file then os.remove(ctx.error_file) end
    -- We cannot kill the shell process easily from Lua standard lib without FFI or specialized extensions
    -- but clearing markers prevents ghost reads.
end

reaper.atexit(cleanup)

local function update_log_display(path)
    if not path or path == "" then return end
    local f = io.open(path, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    
    if #content > ctx.last_log_size then
        ctx.log_lines = {}
        for line in content:gmatch("[^\r\n]+") do
            table.insert(ctx.log_lines, line)
        end
        while #ctx.log_lines > 12 do table.remove(ctx.log_lines, 1) end
        ctx.last_log_size = #content
    end
end

local function draw()
    local c = gfx.getchar()
    if c == 27 or c == -1 then return 0 end
    
    gfx.set(0.12, 0.12, 0.14, 1)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)
    
    gfx.set(0.9, 0.9, 0.9, 1)
    gfx.setfont(1, "Arial", 24)
    gfx.x, gfx.y = 20, 20
    gfx.drawstr(APP_NAME)
    
    gfx.setfont(1, "Arial", 16)
    gfx.y = gfx.y + 40
    gfx.x = 20
    
    local stat_col = {0.8, 0.8, 0.8}
    if ctx.state == STATE_RUNNING or ctx.state == STATE_SETUP_ENV then stat_col = {0.4, 0.8, 1.0} end
    if ctx.state == STATE_ERROR then stat_col = {1.0, 0.4, 0.4} end
    if ctx.state == STATE_DONE then stat_col = {0.4, 1.0, 0.4} end
    
    gfx.set(table.unpack(stat_col))
    gfx.drawstr(ctx.status)
    
    -- UX: Explicit Download Warning
    if ctx.state == STATE_SETUP_ENV then
        gfx.set(1, 0.8, 0.4, 1)
        gfx.y = gfx.y + 25
        gfx.x = 20
        gfx.drawstr("Downloading AI Models (~1GB). This happens only once.")
        gfx.y = gfx.y + 20
        gfx.x = 20
        gfx.drawstr("Please wait... Do not close REAPER.")
    end
    
    -- Loading Bar
    if ctx.state == STATE_RUNNING or ctx.state == STATE_SETUP_ENV then
        gfx.y = gfx.y + 30
        gfx.x = 20
        local w = gfx.w - 40
        -- Simple throbber
        local t = os.clock() * 2
        local x_pos = (t % 1.5) * w
        gfx.set(0.3, 0.3, 0.3, 1)
        gfx.rect(20, gfx.y, w, 4, 0)
        gfx.set(0.4, 0.8, 1, 0.8)
        gfx.rect(20 + x_pos % w, gfx.y, 60, 4, 1)
    end
    
    gfx.y = 200
    gfx.x = 20
    gfx.set(0.6, 0.6, 0.6, 1)
    gfx.setfont(1, "Courier New", 14)
    for _, l in ipairs(ctx.log_lines) do
        gfx.drawstr(l .. "\n")
        gfx.x = 20
    end
    
    gfx.update()
    return 1
end

local function loop()
    -- STATE MACHINE
    if ctx.state == STATE_SETUP_ENV then
        update_log_display(ctx.log_file_path)
        if file_exists(ctx.done_file) then
            ctx.status = "Environment Ready. Starting Demucs..."
            ctx.state = STATE_IDLE 
            ctx.venv_python = get_venv_python_path() 
            -- Proceed to running
            local run_script, r_done, r_err, r_ana, r_list = generate_run_script(ctx.work_dir, ctx.venv_python, ctx.input_file, ctx.log_file_path)
            ctx.done_file = r_done
            ctx.error_file = r_err
            ctx.analysis_out = r_ana
            ctx.list_file = r_list
            ctx.run_script = run_script
            
            ctx.last_log_size = 0
            os.execute("sh " .. escape_for_bash(ctx.run_script) .. " &")
            ctx.state = STATE_RUNNING
            
        elseif file_exists(ctx.error_file) then
            ctx.state = STATE_ERROR
            ctx.status = "Setup Failed. Check Log for details."
        end
        
    elseif ctx.state == STATE_RUNNING then
        update_log_display(ctx.log_file_path)
        if file_exists(ctx.done_file) then
            ctx.state = STATE_DONE
            ctx.status = "Demucs Finished. Importing Stems..."
            
            local analysis = parse_analysis(ctx.analysis_out)
            -- Robust Import: Checks file list inside function
            import_stems(ctx.list_file, analysis, ctx.item_pos, ctx.song_name)
            
            ctx.status = "Done! You can close this window."
        elseif file_exists(ctx.error_file) then
            ctx.state = STATE_ERROR
            ctx.status = "Process Failed. Check Log."
        end
    end
    
    if draw() == 1 then
        reaper.defer(loop)
    end
end

local function start()
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then
        reaper.ShowMessageBox("Select an audio item first.", APP_NAME, 0)
        return
    end
    
    local take = reaper.GetActiveTake(item)
    local source = reaper.GetMediaItemTake_Source(take)
    local filename = reaper.GetMediaSourceFileName(source, "")
    ctx.item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    
    ctx.input_file = filename:gsub("\\", "/")
    ctx.song_name = ctx.input_file:match("([^/]+)%.%w+$") or "Audio"
    
    ctx.work_dir = ensure_work_dir()
    ctx.home_dir = get_home_dir()
    
    -- Check Env (Strict Verification)
    ctx.venv_python = get_venv_python_path()
    
    local env_ok = false
    if file_exists(ctx.venv_python) then
        if verify_venv_libraries(ctx.venv_python) then
             message = "Environment verified."
             env_ok = true
        else
             message = "Environment corrupt. Re-installing..."
             env_ok = false
        end
    else
        message = "No environment found."
        env_ok = false
    end
    
    if env_ok then
        ctx.status = "Environment ready. Processing..."
        
        ctx.log_file_path = ctx.work_dir .. "/run_demucs.log"
        local run_script, r_done, r_err, r_ana, r_list = generate_run_script(ctx.work_dir, ctx.venv_python, ctx.input_file, ctx.log_file_path)
        
        ctx.done_file = r_done
        ctx.error_file = r_err
        ctx.analysis_out = r_ana
        ctx.list_file = r_list
        ctx.run_script = run_script
        
        os.execute("sh " .. escape_for_bash(ctx.run_script) .. " &")
        ctx.state = STATE_RUNNING
    else
        ctx.status = "First time setup: Initializing AI Environment..."
        local sys_py = find_system_python()
        if not sys_py then
            reaper.ShowMessageBox("Error: No system Python 3 found (tried /opt/homebrew, /usr/local, /usr). Please install Python.", APP_NAME, 0)
            return
        end
        ctx.system_python = sys_py
        
        local setup_script, s_done, s_err, s_log = generate_setup_script(ctx.work_dir, ctx.system_python)
        ctx.done_file = s_done
        ctx.error_file = s_err
        ctx.log_file_path = s_log
        
        os.execute("sh " .. escape_for_bash(setup_script) .. " &")
        ctx.state = STATE_SETUP_ENV
    end
    
    gfx.init(APP_NAME, GUI_W, GUI_H)
    loop()
end

start()
