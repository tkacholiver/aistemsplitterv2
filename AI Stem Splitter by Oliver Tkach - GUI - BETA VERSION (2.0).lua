--[[
    REAPER LOCAL AI ENGINEER (ANTIGRAVITY CORE)
    Role: Professional Audio Separation Engine (Universal V3.2 - Analysis Fix for Numpy)
    Target: Windows & Linux
    Changes:
    - Fixed Analysis Script Execution (path quoting & dependency checks)
    - Fixed Numpy Rounding Error (converted ndarray to scalar)
    - Forced numpy<2 for compatibility (librosa issues)
    - Strict Naming Convention (BPM, Key, Hz)

    ONE-TIME SETUP:
    - Windows:
      1) Install Python 3.10+ (recommend 3.12) from python.org. Check "Add Python to PATH".
      2) Install FFmpeg: 'winget install Gyan.FFmpeg' in Admin Terminal.
      3) RESTART REAPER.

    - Linux:
      1) Install Python 3, pip, and ffmpeg.
]]

local APP_NAME = "AI Stem Splitter by Oliver Tkach - Universal 3.2"
local MODEL_NAME = "htdemucs_6s"
local STEM_OUTPUT_FOLDER = "audio_process"
local STEM_NAMES = {"vocals", "drums", "bass", "guitar", "piano", "other"}

local function get_os_info()
    local os_str = reaper.GetOS()
    local is_windows = os_str:match("Win") ~= nil
    local sep = is_windows and "\\" or "/"
    return is_windows, sep
end

local IS_WINDOWS, SEP = get_os_info()

math.randomseed(os.time())

local ctx = {
    state = "init",
    status = "Initializing...",
    detail = "",
    error_message = nil,
    done_message = nil,
    log_file = nil,
    status_file = nil,
    runner_file = nil,
    launcher_file = nil,
    log_tail = "",
    last_log_poll = 0,
    prev_mouse_down = false,
    request_close = false,
    width = 760,
    height = 500,
}

local function path_join(base, leaf)
    return base .. SEP .. leaf
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then
        return false
    end
    f:write(content)
    f:close()
    return true
end

local function dir_exists(path)
    local ok, _, code = os.rename(path, path)
    if ok then
        return true
    end
    return code == 13
end

local function command_succeeded(cmd)
    local ok = os.execute(cmd)
    if type(ok) == "number" then
        return ok == 0
    end
    if type(ok) == "boolean" then
        return ok
    end
    return false
end

-- Strictly quoting arguments for Windows cmd
local function quote_arg_windows(value)
    value = tostring(value or "")
    value = value:gsub('"', '""')
    return '"' .. value .. '"'
end

-- Strictly quoting arguments for Posix sh
local function quote_arg_posix(value)
    value = tostring(value or "")
    value = value:gsub("'", "'\\''")
    return "'" .. value .. "'"
end

local function quote_arg(value)
    if IS_WINDOWS then
        return quote_arg_windows(value)
    end
    return quote_arg_posix(value)
end

-- Helper to force backslashes on Windows
local function normalize_win_path(path)
    if not path then return "" end
    return path:gsub("/", "\\")
end

-- Escape for Python -c '...' (single quoted string)
local function escape_python_single_quoted(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub("'", "\\'")
    return value
end

local function escape_vbs_string(value)
    value = tostring(value or "")
    value = value:gsub('"', '""')
    return value
end

local function ensure_work_dir(path)
    if reaper.RecursiveCreateDirectory then
        reaper.RecursiveCreateDirectory(path, 0)
        return dir_exists(path)
    end

    if IS_WINDOWS then
        os.execute("mkdir " .. quote_arg(path) .. " > nul 2>&1")
    else
        os.execute("mkdir -p " .. quote_arg(path) .. " >/dev/null 2>&1")
    end
    return dir_exists(path)
end

local function can_write_dir(path)
    local probe = path_join(path, ".ai_stem_splitter_probe")
    local f = io.open(probe, "w")
    if not f then
        return false
    end
    f:write("ok")
    f:close()
    os.remove(probe)
    return true
end

local function build_setup_help(python_cmd)
    if IS_WINDOWS then
        return table.concat({
            "One-time setup (Windows):",
            "1) Install Python 3.10+ from python.org.",
            "   IMPORTANT: Check 'Add Python to PATH'.",
            "2) Open Command Prompt, verify 'python --version'.",
            "3) Run:",
            "   pip install demucs soundfile==0.12.1 librosa \"numpy<2\" scipy",
            "4) Install FFmpeg: 'winget install Gyan.FFmpeg'",
            "5) RESTART REAPER."
        }, "\n")
    else
        return table.concat({
            "One-time setup (Linux):",
            "1) Install python3, pip, ffmpeg.",
            "2) pip3 install demucs soundfile librosa \"numpy<2\" scipy",
        }, "\n")
    end
end

local function build_setup_message(reason, python_cmd)
    return reason .. "\n\n" .. build_setup_help(python_cmd)
end

local function set_error(message)
    ctx.state = "error"
    ctx.status = "Error"
    ctx.error_message = message
end

local function set_info(state, status, detail)
    ctx.state = state
    ctx.status = status
    ctx.detail = detail or ""
end

-- ----------------------------------------------------------------------
-- ANALYSIS SCRIPT GENERATOR
-- ----------------------------------------------------------------------
local function build_analysis_script(file_path, output_path, work_dir, debug_path)
    -- This Python script is injected into the runner
    local script = [[
import sys
import os

def run_analysis():
    try:
        # MONKEY PATCH: Fix for old librosa vs new scipy (Missing 'hann')
        import scipy.signal
        if not hasattr(scipy.signal, 'hann'):
            try:
                scipy.signal.hann = scipy.signal.windows.hann
            except AttributeError:
                pass 

        import librosa
        import numpy as np
    except ImportError as e:
        # If librosa/numpy missing, just exit gracefully
        with open(r']] .. output_path .. [[', 'w') as f:
            f.write("||")
        with open(r']] .. debug_path .. [[', 'w') as f:
            f.write(f"ImportError: {e}")
        return

    input_path = r']] .. file_path .. [['
    output_path = r']] .. output_path .. [['
    
    # Force utf-8 for output
    sys.stdout.reconfigure(encoding='utf-8')
    
    try:
        # Load 60s for speed
        y, sr = librosa.load(input_path, sr=None, duration=60)
        
        # 1. BPM
        tempo, _ = librosa.beat.beat_track(y=y, sr=sr)
        
        # FIX: Ensure scalar for rounding
        if hasattr(tempo, 'item'): 
            tempo = tempo.item()
            
        bpm = int(round(tempo)) if tempo else 0
        
        # 2. Key
        chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
        chroma_vals = np.sum(chroma, axis=1)
        maj_profile = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
        min_profile = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
        
        maj_corrs = []
        min_corrs = []
        for i in range(12):
            maj_corrs.append(np.corrcoef(np.roll(maj_profile, i), chroma_vals)[0, 1])
            min_corrs.append(np.corrcoef(np.roll(min_profile, i), chroma_vals)[0, 1])
            
        key_names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
        if np.max(maj_corrs) > np.max(min_corrs):
            key = key_names[np.argmax(maj_corrs)]
        else:
            key = key_names[np.argmax(min_corrs)] + "m"
            
        # 3. Tuning (Hz)
        tuning_offset = librosa.estimate_tuning(y=y, sr=sr)
        # Fix potential array return
        if hasattr(tuning_offset, 'item'):
            tuning_offset = tuning_offset.item()
            
        detected_hz = 440 * (2 ** (tuning_offset / 12))
        detected_hz = int(round(detected_hz))
        
        with open(output_path, 'w') as f:
            f.write(f"{bpm}|{key}|{detected_hz}")
            
    except Exception as e:
        import traceback
        with open(r']] .. output_path .. [[', 'w') as f:
            f.write(f"||")
        with open(r']] .. debug_path .. [[', 'w') as f:
            f.write(f"RuntimeError: {e}\n{traceback.format_exc()}")

if __name__ == '__main__':
    run_analysis()
]]
    return script
end

local function read_analysis_info(work_dir)
    local info_path = path_join(work_dir, "analysis_info.txt")
    local data = read_file(info_path)
    
    if not data or data == "||" or data == "" then 
        local debug_path = path_join(work_dir, "analysis_debug.log")
        local err = read_file(debug_path)
        if err and err ~= "" then
            reaper.ShowConsoleMsg("\n[Analysis Error] " .. err .. "\n")
        end
        return nil 
    end
    
    local parts = {}
    for str in string.gmatch(data, "([^|]+)") do
        table.insert(parts, str)
    end
    
    if #parts >= 3 then
        return {
            bpm = parts[1],
            key = parts[2],
            hz = parts[3]
        }
    end
    return nil
end

-- ----------------------------------------------------------------------
-- EXECUTION BUILDERS
-- ----------------------------------------------------------------------

local function build_demucs_command_line(is_win, model, filename_tmpl, file_path, work_dir)
    if is_win then
        -- Windows: Double Quotes for paths
        return table.concat({
            "-m demucs.separate",
            "-n " .. model,
            "--filename \"" .. filename_tmpl .. "\"",
            "!EXTRA_ARGS!",
            "\"" .. file_path .. "\"",
            "-o \"" .. work_dir .. "\""
        }, " ")
    else
        -- POSIX: Single Quoting
        return table.concat({
            "-m demucs.separate",
            "-n " .. model,
            "--filename " .. quote_arg_posix(filename_tmpl),
            "$EXTRA_ARGS",
            quote_arg_posix(file_path),
            "-o " .. quote_arg_posix(work_dir)
        }, " ")
    end
end

local function build_windows_runner_async(work_dir, song_name, file_path, log_path, status_path)
    -- 1. WINDOWS PATH NORMALIZATION (Backslashes)
    local safe_file_path = normalize_win_path(file_path)
    local safe_work_dir = normalize_win_path(work_dir)
    local safe_log = normalize_win_path(log_path)
    local safe_status = normalize_win_path(status_path)
    
    local probe_path = normalize_win_path(path_join(work_dir, "torchaudio_write_probe.wav"))
    local analysis_script = normalize_win_path(path_join(work_dir, "analyze_audio.py"))
    local analysis_output = normalize_win_path(path_join(work_dir, "analysis_info.txt"))
    local analysis_debug = normalize_win_path(path_join(work_dir, "analysis_debug.log"))
    
    -- 2. CREATE ANALYSIS SCRIPT
    local analysis_content = build_analysis_script(safe_file_path, analysis_output, safe_work_dir, analysis_debug)
    write_file(analysis_script, analysis_content)

    -- 3. BUILD DEMUCS ARGS
    local filename_tmpl = STEM_OUTPUT_FOLDER .. "/{stem}.{ext}"
    filename_tmpl = filename_tmpl:gsub("/", "\\")
    local demucs_args = build_demucs_command_line(true, MODEL_NAME, filename_tmpl, safe_file_path, safe_work_dir)

    -- 4. BATCH SCRIPT
    return table.concat({
        "@echo off",
        "setlocal EnableDelayedExpansion",
        "chcp 65001 > nul", -- UTF-8 support
        "set \"CODE=0\"",
        "set \"PY_CMD=\"",
        "set \"EXTRA_ARGS=\"",
        "",
        ":: redirect output",
        "call :run > \"" .. safe_log .. "\" 2>&1",
        "echo !CODE! > \"" .. safe_status .. "\"",
        "exit /b !CODE!",
        "",
        ":run",
        "echo [preflight] Searching for Python 3.10+...",
        "",
        ":: DYNAMIC SEARCH LOOP",
        ":: Checks: python, python3, py -3, py",
        "for %%C in (python python3 \"py -3\" py) do (",
        "  if not defined PY_CMD (",
        "    %%~C -c \"import sys; print(sys.version_info[:2] >= (3, 10))\" | findstr \"True\" > nul",
        "    if !errorlevel! equ 0 set \"PY_CMD=%%~C\"",
        "  )",
        ")",
        "",
        "if not defined PY_CMD (",
        "  echo [error] No valid Python 3.10+ found in PATH.",
        "  set \"CODE=11\"",
        "  goto :eof",
        ")",
        "",
        "echo [preflight] Selected Python: !PY_CMD!",
        "",
        "echo [preflight] Verifying Demucs...",
        "\"!PY_CMD!\" -m demucs --help > nul",
        "if errorlevel 1 (",
        "  echo [preflight] Demucs not found. Attempting AUTO-INSTALL...",
        "  echo [install] Installing demucs soundfile librosa numpy<2 scipy...",
        "  \"!PY_CMD!\" -m pip install demucs soundfile==0.12.1 librosa \"numpy<2\" scipy > nul 2>&1",
        "  if errorlevel 1 (",
        "    echo [error] Auto-install failed.",
        "    echo [hint] Please run manually: pip install demucs soundfile librosa \"numpy<2\" scipy",
        "    set \"CODE=12\"",
        "    goto :eof",
        "  )",
        "  echo [install] Installation successful.",
        ")",
        "",
        "echo [preflight] Checking FFmpeg...",
        "ffmpeg -version > nul 2>&1",
        "if errorlevel 1 (",
        "  echo [error] FFmpeg not found in PATH.",
        "  echo [hint] Please run: winget install Gyan.FFmpeg in ADMIN terminal and RESTART REAPER.",
        "  set \"CODE=13\"",
        "  goto :eof",
        ")",
        "",
        "echo [preflight] Clearing workspace...",
        "rmdir /S /Q \"" .. normalize_win_path(path_join(path_join(work_dir, MODEL_NAME), STEM_OUTPUT_FOLDER)) .. "\" > nul 2>&1",
        "rmdir /S /Q \"" .. normalize_win_path(path_join(path_join(work_dir, MODEL_NAME), song_name)) .. "\" > nul 2>&1",
        "",
        "echo [preflight] Probing export...",
        "\"!PY_CMD!\" -c \"import os, torch, torchaudio as ta; p=r'" .. probe_path .. "'; x=torch.zeros(2, 512); ta.save(p, x, 44100); os.remove(p)\" > nul 2>&1",
        "if errorlevel 1 (",
        "  set \"EXTRA_ARGS=--mp3 --mp3-bitrate 320\"",
        "  echo [info] WAV export unavailable. Fallback to MP3.",
        ")",
        "",
        "echo [analysis] Analyzing audio (BPM/Key/Hz)...",
        "\"!PY_CMD!\" \"" .. analysis_script .. "\"",
        "",
        "echo [run] Running Demucs...",
        ":: STRICT QUOTING for Execution",
        "\"!PY_CMD!\" " .. demucs_args,
        "",
        "if errorlevel 1 (",
        "  set \"CODE=!ERRORLEVEL!\"",
        "  echo [error] Demucs failed.",
        "  goto :eof",
        ")",
        "",
        "echo [ok] Processing finished.",
        "set \"CODE=0\"",
        "goto :eof"
    }, "\r\n")
end

local function build_linux_runner_async(work_dir, song_name, file_path, log_path, status_path)
    -- Linux runner (No Mac Logic)
    local analysis_script = path_join(work_dir, "analyze_audio.py")
    local analysis_output = path_join(work_dir, "analysis_info.txt")
    local analysis_debug = path_join(work_dir, "analysis_debug.log")
    
    local analysis_content = build_analysis_script(file_path, analysis_output, work_dir, analysis_debug)
    write_file(analysis_script, analysis_content)

    local filename_tmpl = STEM_OUTPUT_FOLDER .. "/{stem}.{ext}"
    local demucs_args = build_demucs_command_line(false, MODEL_NAME, filename_tmpl, file_path, work_dir)
    
    local probe_path = path_join(work_dir, "torchaudio_write_probe.wav")
    local old_template = path_join(path_join(work_dir, MODEL_NAME), STEM_OUTPUT_FOLDER)
    local old_named = path_join(path_join(work_dir, MODEL_NAME), song_name)

    return table.concat({
        "#!/bin/sh",
        "PATH=\"$PATH:/usr/local/bin:/usr/bin:/bin\"",
        "export PATH",
        "CODE=0",
        "PY_CMD=\"\"",
        "EXTRA_ARGS=\"\"",
        "run() {",
        "  echo \"[preflight] Searching for Python 3.10+...\"",
        "  for cmd in python3 python; do",
        "    if command -v $cmd >/dev/null 2>&1; then",
        "       $cmd -c \"import sys; print(sys.version_info[:2] >= (3, 10))\" | grep \"True\" >/dev/null 2>&1",
        "       if [ $? -eq 0 ]; then",
        "         PY_CMD=$cmd",
        "         break",
        "       fi",
        "    fi",
        "  done",
        "",
        "  if [ -z \"$PY_CMD\" ]; then",
        "    echo \"[error] No Python 3.10+ found.\"",
        "    CODE=11",
        "    return",
        "  fi",
        "  echo \"[preflight] Using Python: $PY_CMD\"",
        "",
        "  echo \"[preflight] Checking Demucs...\"",
        "  \"$PY_CMD\" -m demucs --help >/dev/null 2>&1",
        "  if [ $? -ne 0 ]; then",
        "    echo \"[preflight] Demucs missing. Auto-installing...\"",
        "    \"$PY_CMD\" -m pip install demucs soundfile librosa \"numpy<2\" scipy >/dev/null 2>&1",
        "    if [ $? -ne 0 ]; then",
        "      echo \"[error] Auto-install failed.\"",
        "      CODE=12",
        "      return",
        "    fi",
        "  fi",
        "",
        "  echo \"[preflight] Checking FFmpeg...\"",
        "  command -v ffmpeg >/dev/null 2>&1",
        "  if [ $? -ne 0 ]; then",
        "    echo \"[error] FFmpeg not found.\"",
        "    CODE=13",
        "    return",
        "  fi",
        "",
        "  echo \"[preflight] Cleaning...\"",
        "  rm -rf " .. quote_arg_posix(old_template) .. " " .. quote_arg_posix(old_named),
        "",
        "  echo \"[preflight] Probing export...\"",
        "  \"$PY_CMD\" -c \"import os, torch, torchaudio as ta; p='" .. escape_python_single_quoted(probe_path) .. "'; x=torch.zeros(2, 512); ta.save(p, x, 44100); os.remove(p)\" >/dev/null 2>&1",
        "  if [ $? -ne 0 ]; then",
        "    EXTRA_ARGS=\"--mp3 --mp3-bitrate 320\"",
        "    echo \"[info] WAV export unavailable. Fallback to MP3.\"",
        "  fi",
        "",
        "  echo \"[analysis] Analyzing audio...\"",
        "  \"$PY_CMD\" " .. quote_arg_posix(analysis_script),
        "",
        "  echo \"[run] Running Demucs...\"",
        "  \"$PY_CMD\" " .. demucs_args,
        "  if [ $? -ne 0 ]; then",
        "    CODE=$?",
        "    echo \"[error] Demucs failed.\"",
        "    return",
        "  fi",
        "  echo \"[ok] Done.\"",
        "  CODE=0",
        "}",
        "run > " .. quote_arg_posix(log_path) .. " 2>&1",
        "echo \"$CODE\" > " .. quote_arg_posix(status_path),
        "exit \"$CODE\"",
        ""
    }, "\n")
end

local function start_demucs_async()
    local run_id = tostring(math.floor(reaper.time_precise() * 1000)) .. "_" .. tostring(math.random(1000, 9999))
    ctx.log_file = path_join(ctx.work_dir, "demucs_" .. run_id .. ".log")
    ctx.status_file = path_join(ctx.work_dir, "demucs_" .. run_id .. ".status")
    
    os.remove(ctx.log_file)
    os.remove(ctx.status_file)
    
    local runner_script
    local launch_cmd
    
    if IS_WINDOWS then
        ctx.runner_file = path_join(ctx.work_dir, "demucs_" .. run_id .. ".cmd")
        ctx.launcher_file = path_join(ctx.work_dir, "demucs_" .. run_id .. ".vbs")
        
        runner_script = build_windows_runner_async(ctx.work_dir, ctx.song_name, ctx.file_path, ctx.log_file, ctx.status_file)
        
        local launch_vbs = table.concat({
            'Set shell = CreateObject("WScript.Shell")',
            'shell.Run "cmd /C ""' .. escape_vbs_string(ctx.runner_file) .. '""", 0, False',
            ""
        }, "\r\n")
        
        write_file(ctx.launcher_file, launch_vbs)
        launch_cmd = "wscript //nologo " .. quote_arg_windows(ctx.launcher_file)
    else
        ctx.runner_file = path_join(ctx.work_dir, "demucs_" .. run_id .. ".sh")
        ctx.launcher_file = nil
        
        runner_script = build_linux_runner_async(ctx.work_dir, ctx.song_name, ctx.file_path, ctx.log_file, ctx.status_file)
        
        launch_cmd = "sh " .. quote_arg_posix(ctx.runner_file) .. " >/dev/null 2>&1 &"
    end

    if not write_file(ctx.runner_file, runner_script) then
        set_error("Could not write runner script:\n" .. ctx.runner_file)
        return
    end

    if not command_succeeded(launch_cmd) then
        set_error("Failed to launch process.")
        return
    end

    ctx.started_at = reaper.time_precise()
    ctx.last_log_poll = 0
    set_info("running", "Processing...", "Using external Python environment.")
end

local function find_stem_path(stems_dir, stem_name)
    local wav = path_join(stems_dir, stem_name .. ".wav")
    if file_exists(wav) then return wav end
    local mp3 = path_join(stems_dir, stem_name .. ".mp3")
    if file_exists(mp3) then return mp3 end
    return nil
end

local function resolve_stems_dir(work_dir, song_name)
    local base = path_join(work_dir, MODEL_NAME)
    local candidates = {
        path_join(base, STEM_OUTPUT_FOLDER),
        path_join(base, song_name)
    }
    for _, dir in ipairs(candidates) do
        if find_stem_path(dir, "vocals") then return dir end
    end
    return candidates[1]
end

local function import_stems(song_name, pos, stems_dir, analysis)
    reaper.Undo_BeginBlock()
    
    local folder_index = reaper.GetNumTracks()
    reaper.InsertTrackAtIndex(folder_index, true)
    local folder_tr = reaper.GetTrack(0, folder_index)
    
    local title = "STEMS: " .. song_name
    if analysis then
        title = title .. " [" .. analysis.bpm .. "bpm " .. analysis.key .. " @" .. analysis.hz .. "Hz]"
    end
    reaper.GetSetMediaTrackInfo_String(folder_tr, "P_NAME", title, true)
    reaper.SetMediaTrackInfo_Value(folder_tr, "I_FOLDERDEPTH", 1)
    
    reaper.Main_OnCommand(40297, 0) -- Unselect all
    
    for _, stem_name in ipairs(STEM_NAMES) do
        local path = find_stem_path(stems_dir, stem_name)
        if path then
            local idx = reaper.GetNumTracks()
            reaper.InsertTrackAtIndex(idx, true)
            local tr = reaper.GetTrack(0, idx)
            local stem_title = string.upper(stem_name)
            
            reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", stem_title, true)
            reaper.SetOnlyTrackSelected(tr)
            reaper.SetEditCurPos(pos, false, false)
            
            if reaper.InsertMedia(path, 0) then
                local item = reaper.GetTrackMediaItem(tr, 0)
                if item then
                    local take = reaper.GetActiveTake(item)
                    if take then
                         local take_name = song_name
                         if analysis then
                             take_name = take_name .. " (" .. analysis.bpm .. "bpm " .. analysis.key .. " @" .. analysis.hz .. "Hz)"
                         end
                         take_name = take_name .. " - " .. stem_name
                         reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", take_name, true)
                    end
                end
            end
        end
    end
    
    local last = reaper.GetTrack(0, reaper.GetNumTracks()-1)
    reaper.SetMediaTrackInfo_Value(last, "I_FOLDERDEPTH", -1)
    
    reaper.Undo_EndBlock("Import AI Stems", -1)
    reaper.UpdateArrange()
end

local function get_last_nonempty_lines(path, max_lines)
    local data = read_file(path)
    if not data or data == "" then return "" end
    local lines = {}
    for line in data:gmatch("[^\r\n]+") do
        if line and line ~= "" then lines[#lines+1] = line end
    end
    if #lines == 0 then return "" end
    local start = math.max(1, #lines - (max_lines or 20) + 1)
    local out = {}
    for i=start, #lines do out[#out+1] = lines[i] end
    return table.concat(out, "\n")
end

local function get_last_line(path)
    local data = read_file(path)
    if not data or data == "" then return "" end
    local last = ""
    for line in data:gmatch("[^\r\n]+") do
        if line and line ~= "" then last = line end
    end
    return last
end

local function finalize_processing()
    local code_raw = read_file(ctx.status_file) or ""
    local exit_code = tonumber(code_raw:match("(-?%d+)")) or 1

    if exit_code ~= 0 then
        local msg = "Demucs failed (Code " .. exit_code .. ")."
        local tail = get_last_nonempty_lines(ctx.log_file, 15)
        if tail ~= "" then msg = msg .. "\n\nLog tail:\n" .. tail end
        
        if exit_code == 11 then
            msg = build_setup_message("No Python 3.10+ found.", nil)
        elseif exit_code == 12 then
            msg = build_setup_message("Dependencies missing (demucs/librosa).", nil)
        elseif exit_code == 13 then
            msg = build_setup_message("FFmpeg missing. Run in ADMIN cmd:\nwinget install Gyan.FFmpeg\nThen Restart REAPER.", nil)
        end
        
        set_error(msg)
        return
    end

    local stems_dir = resolve_stems_dir(ctx.work_dir, ctx.song_name)
    if not find_stem_path(stems_dir, "vocals") then
        set_error("Finished but no stems found at:\n" .. stems_dir)
        return
    end

    set_info("importing", "Importing...", "Please wait.")
    local analysis = read_analysis_info(ctx.work_dir)
    import_stems(ctx.song_name, ctx.pos, stems_dir, analysis)

    ctx.done_message = "Done. Stems imported."
    set_info("done", "Done", "You can close this window.")
    
    if ctx.runner_file then os.remove(ctx.runner_file) end
    if ctx.launcher_file then os.remove(ctx.launcher_file) end
    if ctx.status_file then os.remove(ctx.status_file) end
end

local function update_running_state()
    if ctx.state ~= "running" then return end
    
    local now = reaper.time_precise()
    if (now - ctx.last_log_poll) > 0.75 then
        ctx.last_log_poll = now
        if ctx.log_file then
            ctx.log_tail = get_last_line(ctx.log_file)
            if ctx.log_tail and ctx.log_tail:find("Fallback to MP3", 1, true) then
                if not (ctx.detail or ""):find("MP3", 1, true) then
                    ctx.detail = (ctx.detail or "") .. " (MP3 Mode)"
                end
            end
        end
    end
    
    if ctx.status_file and file_exists(ctx.status_file) then
        finalize_processing()
    end
end

local function initialize_context()
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then
        set_error("Select an audio item first.")
        return
    end
    local take = reaper.GetActiveTake(item)
    if not take then set_error("No active take.") return end
    local src_path = reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(take), "")
    if not src_path or src_path == "" then set_error("Bad source file.") return end

    ctx.item = item
    ctx.file_path = src_path
    ctx.pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    
    local name = src_path:match(".*[/\\](.*)") or src_path
    ctx.song_name = name:match("(.+)%.[^%.]+") or name

    local res_path = reaper.GetResourcePath() -- Get Reaper path
    if IS_WINDOWS then res_path = res_path:gsub("/", "\\") end
    
    local work_dir = path_join(path_join(res_path, "Data"), "AI_Stems_Data")
    ensure_work_dir(work_dir)
    
    if not can_write_dir(work_dir) then
        set_error("Cannot write to:\n" .. work_dir)
        return
    end
    
    ctx.work_dir = work_dir
    start_demucs_async()
end

-- GUI
local function wrap_text(text, max_w)
    local out = {}
    local line = ""
    for word in tostring(text):gmatch("%S+") do
        local cand = (line == "") and word or (line .. " " .. word)
        if gfx.measurestr(cand) <= max_w then line = cand
        else
            if line ~= "" then out[#out+1] = line end
            line = word
        end
    end
    if line ~= "" then out[#out+1] = line end
    return out
end

local function draw_gui()
    gfx.set(0.08, 0.09, 0.11, 1)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)

    gfx.setfont(1, "Arial", 20)
    gfx.set(0.9, 0.9, 0.9, 1)
    gfx.x, gfx.y = 20, 20
    gfx.drawstr(APP_NAME)
    
    gfx.setfont(1, "Arial", 16)
    gfx.set(0.7, 0.8, 1, 1)
    gfx.x, gfx.y = 20, 50
    gfx.drawstr("Status: " .. (ctx.status or ""))

    gfx.setfont(1, "Arial", 14)
    gfx.set(0.8, 0.8, 0.8, 1)
    
    local y = 80
    if ctx.detail and ctx.detail ~= "" then
        for _, l in ipairs(wrap_text(ctx.detail, gfx.w - 40)) do
            gfx.x, gfx.y = 20, y
            gfx.drawstr(l)
            y = y + 16
        end
    end
    
    if ctx.log_tail and ctx.log_tail ~= "" then
        y = y + 10
        gfx.set(0.5, 0.5, 0.5, 1)
        gfx.x, gfx.y = 20, y
        gfx.drawstr("Log: " .. ctx.log_tail)
        y = y + 16
    end
    
    if ctx.error_message then
        y = y + 10
        gfx.set(1, 0.4, 0.4, 1)
        for _, l in ipairs(wrap_text(ctx.error_message, gfx.w - 40)) do
            gfx.x, gfx.y = 20, y
            gfx.drawstr(l)
            y = y + 16
        end
    elseif ctx.done_message then
        y = y + 10
        gfx.set(0.4, 1, 0.4, 1)
        gfx.x, gfx.y = 20, y
        gfx.drawstr(ctx.done_message)
    end
    
    -- Close button
    local bw, bh = 80, 30
    local bx, by = gfx.w - bw - 20, gfx.h - bh - 20
    gfx.set(0.3, 0.3, 0.3, 1)
    gfx.rect(bx, by, bw, bh, 1)
    gfx.set(1, 1, 1, 1)
    local tw, th = gfx.measurestr("Close")
    gfx.x = bx + (bw-tw)/2
    gfx.y = by + (bh-th)/2
    gfx.drawstr("Close")
    
    if (gfx.mouse_cap & 1) == 1 and gfx.mouse_x >= bx and gfx.mouse_x <= bx+bw and gfx.mouse_y >= by and gfx.mouse_y <= by+bh then
        if not ctx.prev_mouse_down then ctx.request_close = true end
    end
    ctx.prev_mouse_down = (gfx.mouse_cap & 1) == 1
end

local function loop()
    if gfx.getchar() < 0 or ctx.request_close then return end
    update_running_state()
    draw_gui()
    gfx.update()
    reaper.defer(loop)
end

gfx.init(APP_NAME, ctx.width, ctx.height)
initialize_context()
loop()
