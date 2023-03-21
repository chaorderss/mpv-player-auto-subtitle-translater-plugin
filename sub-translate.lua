local mp = require 'mp'
local utils = require 'mp.utils'
local json = require 'dkjson'

-- Set your desired target language here
local target_language = "zh-CN"
-- Global table for translated subtitles
translated_subs = {}
-- Set the pre-fetch delay in seconds
local pre_fetch_delay = 1
-- Set the path to the output subtitle file
local prev_translated_id = nil
local prev_original_id = nil

local function on_file_loaded()
    local video_path = mp.get_property("path")

    if video_path then
        local video_dir, video_name = utils.split_path(video_path)
        local video_name_no_ext = video_name:match("(.+)%..+$")
        local output_sub_file = utils.join_path(video_dir, video_name_no_ext .. ".ass")
        mp.msg.info("output_sub_file:" .. output_sub_file)
        -- Continue with the rest of your script
    else
        mp.msg.error("No video loaded.")
        return
    end
end


-- Set the stream index of the embedded subtitle you want to extract
local stream_index = 0

local function urlencode(str)
    if str then
        str = string.gsub(str, "\n", "\r\n")
        str = string.gsub(str, "([^%w%-%.%_%~ ])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        str = string.gsub(str, " ", "+")
    end
    return str
end

local function extract_embedded_subtitles(video_file, output_sub_file, stream_index)
    local args = {
        "ffmpeg", "-y", "-nostdin", "-i", video_file,
        "-c:s", "copy", "-vn", "-an", "-map", "0:s:" .. tostring(stream_index), output_sub_file
    }

    local res = utils.subprocess({ args = args })
    if res.status ~= 0 then
        mp.msg.error("Failed to extract embedded subtitles using ffmpeg")
        mp.msg.error(res.stdout)
        mp.msg.error(res.stderr)
        return false
    end

    return true
end

local function print_current_and_next_translated_subs(movie_time)
    print("Current and next 3 translated subtitles:")
    local found_count = 0

    for _, sub in ipairs(subs) do
        local start_time_seconds = convert_time_to_seconds(sub.start_time)
        local end_time_seconds = convert_time_to_seconds(sub.end_time)

        if found_count < 4 and movie_time <= end_time_seconds then
            local translated_text = translated_subs[sub.start_time] or ""
            print("[" .. sub.start_time .. "] " .. translated_text)
            found_count = found_count + 1
        end
    end
end


local function translate(text, target_language)
    local url_request = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=" .. target_language .. "&dt=t&q=" .. urlencode(text)

    local res, err = utils.subprocess({ args = { "curl", "-s", "-S", "-f", url_request } })

    if not res then
        mp.msg.error("Translation error: Failed to execute curl")
        return nil
    elseif res.status ~= 0 then
        mp.msg.error("Translation error: HTTP error code: " .. tostring(res.status))
        return nil
    end

    local result = json.decode(res.stdout)

    if result and result[1] and result[1][1] and result[1][1][1] then
        return result[1][1][1]
    else
        mp.msg.error("Translation error: Unable to parse JSON response")
        return nil
    end
end

local function convert_time_to_seconds(time)
    local hours, minutes, seconds, milliseconds = string.match(time, "(%d+):(%d+):(%d+)[,%.](%d+)")
    return tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds) + tonumber(milliseconds) / 1000
end

local function should_display_subtitle(sub, movie_time, pre_fetch_delay)
    local start_time_seconds = convert_time_to_seconds(sub.start_time)
    local end_time_seconds = convert_time_to_seconds(sub.end_time)

    local result = movie_time >= (start_time_seconds - pre_fetch_delay) and movie_time <= end_time_seconds

    if result then
        print("Subtitle match found - movie_time:", movie_time, " start_time_seconds:", start_time_seconds, " end_time_seconds:", end_time_seconds)
    end

    return result
end

local function format_ass_time(seconds)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = math.floor(seconds % 60)
    local centisecs = math.floor((seconds * 100) % 100)
    return string.format("%02d:%02d:%02d.%02d", hours, minutes, secs, centisecs)
end

local function display_subtitles(original_text, translated_text, start_time, end_time)
    local duration = (end_time - start_time) * 1000
    local formatted_original_text = string.gsub(original_text, "\\N", "\n")
    local formatted_translated_text = string.gsub(translated_text, "\\N", "\n")
    local text_to_show = string.format("%s\n\n%s", formatted_original_text, formatted_translated_text)

    print("text_to_show",text_to_show)
    -- "show-text '${osd-ass-cc/0}{\\an5}${osd-ass-cc/1}%s' %i"
    --local command_string = string.format("show-text '${osd-ass-cc/0}{\\an5}${osd-ass-cc/1}%s' %i", formatted_translated_text, duration)
    local command_string = string.format("show-text '${osd-ass-cc/0}{\\an2}%s' %i", text_to_show, duration)
    -- Modify the following line to include custom positioning and alignment
    mp.command(command_string)

end

local function display_subtitle(subs, movie_time)
    for i, sub in ipairs(subs) do
        if should_display_subtitle(sub, movie_time, pre_fetch_delay) then
            local translated_text = translated_subs[sub.start_time] or sub.text
            if translated_text then
                translated_subs[sub.start_time] = translated_text
                local start_time_seconds = convert_time_to_seconds(sub.start_time) - pre_fetch_delay
                local end_time_seconds = convert_time_to_seconds(sub.end_time)

                -- Check if the next subtitle's start time is now
                local next_sub = subs[i + 1]
                if next_sub then
                    local next_start_time_seconds = convert_time_to_seconds(next_sub.start_time)
                    if next_start_time_seconds <= movie_time then
                        -- Remove current subtitle
                        table.remove(subs, i)

                        -- Display and translate the next subtitle
                        display_subtitle(subs, movie_time)
                        return
                    end
                end

                display_subtitles(sub.text, translated_text, start_time_seconds + pre_fetch_delay, end_time_seconds)
            end
            break
        end
    end
end



local lfs = require("lfs")

local function read_file(path)
    local file_content = ""
    mp.msg.info('read_file:'..path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    for line in file:lines() do
        file_content = file_content .. line .. "\n"
    end

    file:close()
    return file_content
end

local function table_to_string(t)
    local result = {}
    for k, v in ipairs(t) do
        result[k] = string.format("{start_time = %s, end_time = %s, text = %s}", v.start_time, v.end_time, v.text)
    end
    return "{" .. table.concat(result, ", ") .. "}"
end

-- Function to convert subtitles table to a string representation
local function subtitles_to_string(subs)
    local result = "{"
    for i, sub in ipairs(subs) do
        result = result .. string.format("\n[%d] start_time: %s, end_time: %s, text: %s", i, sub.start_time, sub.end_time, sub.text)
        if i < #subs then
            result = result .. ","
        end
    end
    result = result .. "\n}"
    return result
end


local function get_subtitles_from_file(sub_file)
    mp.msg.info('function get_subtitles_from_file sub file:' .. sub_file)
    -- local subtitle_file_path = "/Users/xmxx/Downloads/Star.Trek.Picard.S03E04.1080p.WEB.H264-CAKES[rarbg]/star.trek.picard.s03e04.1080p.web.h264-cakes.ass"
    local subtitle_content = read_file(sub_file)

    local subs = {} -- Add this line to initialize the subs table

    if not subtitle_content then
        print("get_subtitles_from_file Failed to load subtitles from file")
    else
        print("Subtitle content:")
        --print(subtitle_content)
    end

    for layer, start_time, end_time, style, name, marginL, marginR, marginV, effect, text in string.gmatch(subtitle_content, "Dialogue: (%d+),(%d+:%d+:%d+[,.]%d+),(%d+:%d+:%d+[,.]%d+),([^,]*),([^,]*),(%d+),(%d+),(%d+),([^,]*),([^%s].-)\n") do
        --print("get_subtitles_from_file",start_time, end_time,text)
        table.insert(subs, { start_time = start_time, end_time = end_time, text = text })
    end

    print('get_subtitles_from_file',table_to_string(subs))
    return subs
end


local function main()
    local video_file = mp.get_property("path")
    if not video_file then
        mp.msg.error("No video file loaded")
        return
    end

    -- Generate the output_sub_file path based on the video_file path
        local video_dir, video_name = utils.split_path(video_file)
        local video_name_no_ext = video_name:match("(.+)%..+$")
        local output_sub_file = utils.join_path(video_dir, video_name_no_ext .. ".ass")

    mp.msg.info("output_sub_file: ".. output_sub_file)

    if not extract_embedded_subtitles(video_file, output_sub_file, stream_index) then
        mp.msg.error("Failed to extract embedded subtitles")
        return
    end


    subs = get_subtitles_from_file(output_sub_file)
    if not subs then
        mp.msg.error("main Failed to load subtitles from file")
        return
    end


end

-- Helper function to check if a subtitle is already translated
local function is_translated(sub)
    return translated_subs[sub.start_time] ~= nil
end

-- Event handler for the "time-pos" property
local function on_time_pos_change(_, movie_time)
    if not movie_time then return end
    if not subs or #subs == 0 then return end
    --print_current_and_next_translated_subs(movie_time)
    local current_subtitles = {}
    local next_subs_count = 0
    local min_time_diff = 10

    for i, sub in ipairs(subs) do
        local start_time_seconds = convert_time_to_seconds(sub.start_time)
        local end_time_seconds = convert_time_to_seconds(sub.end_time)

        if movie_time >= start_time_seconds and movie_time <= end_time_seconds then
            table.insert(current_subtitles, sub)
        elseif movie_time < start_time_seconds then
            if next_subs_count < 4 or (start_time_seconds - movie_time) < min_time_diff then
                table.insert(current_subtitles, sub)
                next_subs_count = next_subs_count + 1
            else
                break
            end
        end
    end

    if #current_subtitles > 0 then
        --print("on_time_pos_change current_subtitles:", subtitles_to_string(current_subtitles))
        for i, sub in ipairs(current_subtitles) do
            if not is_translated(sub) then
                local translated_text = translate(sub.text, target_language)
                --print('translated_text: ',translated_text)
                if translated_text then
                    translated_subs[sub.start_time] = translated_text
                end
            end
        end
        display_subtitle(current_subtitles, movie_time)
    else
        print("No matching subtitle found for movie_time:", movie_time)
    end
end


-- Observe the "time-pos" property to display subtitles at the correct time
--mp.observe_property("time-pos", "number", on_time_pos_change)
local function timer_callback()
    local movie_time = mp.get_property_number("time-pos")
    on_time_pos_change(nil, movie_time)
end

local timer = mp.add_periodic_timer(0.2, timer_callback)

mp.register_event("file-loaded", main)
mp.register_event("file-loaded", on_file_loaded)

