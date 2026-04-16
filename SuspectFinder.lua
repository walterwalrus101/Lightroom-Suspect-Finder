--[[
  SuspectFinder.lua — Suspect Finder plugin
  ─────────────────────────────────────────────────────────────────────────────
  Scans the entire catalog and flags photos that likely received incorrect
  keywords copied from a different file that happened to share the same name.

  A photo is a "suspect" when its filename (case-insensitive) appears on 2 or
  more photos in the catalog AND at least ONE of these is true:

    A.  The group contains photos with different capture dates — i.e. these are
        genuinely different images that were keyworded as if they were the same.
    B.  The photo's long side is under LONG_SIDE_THRESHOLD pixels — i.e. it is
        a lower-res copy that may have inherited keywords from the high-res original.

  Flagged photos get the keyword "keyword-suspect".
  A Smart Collection "Suspect Finder → Needs Re-Keywording" is created
  automatically so you can select all suspects in one click and send them to
  Keyworder Supreme.
--]]

local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'
local LrTasks           = import 'LrTasks'

-- ── Config ────────────────────────────────────────────────────────────────────
local LONG_SIDE_THRESHOLD = 3000   -- pixels — lower-res copies below this are suspects

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Returns the long side in pixels (respecting rotation).
local function longSide(photo)
    local w = photo:getRawMetadata('width')  or 0
    local h = photo:getRawMetadata('height') or 0
    local o = photo:getRawMetadata('orientation') or ''
    if o == 'BC' or o == 'DA' then w, h = h, w end
    return math.max(w, h)
end

-- Returns capture date as a number (seconds), or nil if unavailable.
-- Truncated to whole-day granularity so minor time-stamp differences
-- between edited copies don't cause false positives.
local function captureDay(photo)
    local dt = photo:getRawMetadata('dateTimeOriginal')
    if type(dt) == 'number' and dt > 0 then
        return math.floor(dt / 86400)   -- day-level granularity
    end
    return nil
end

-- ── Main ──────────────────────────────────────────────────────────────────────
local catalog = LrApplication.activeCatalog()

LrFunctionContext.callWithContext('SuspectFinder', function(_ctx)
    LrTasks.startAsyncTask(function()

        -- ── Step 1: load all photos ────────────────────────────────────────────
        local scanProgress = LrProgressScope {
            title = 'Suspect Finder: scanning catalog…',
        }
        scanProgress:setCaption('Loading photo list…')
        LrTasks.yield()

        local allPhotos = catalog:getAllPhotos()
        local total     = #allPhotos

        if total == 0 then
            scanProgress:done()
            LrDialogs.message('Suspect Finder', 'The catalog contains no photos.', 'info')
            return
        end

        -- ── Step 2: group by filename, collecting date + size per photo ────────
        local byFilename = {}   -- filename (lower) → { { photo, day, ls }, … }

        for i, photo in ipairs(allPhotos) do
            if scanProgress:isCanceled() then
                scanProgress:done(); return
            end
            if i % 200 == 0 then
                scanProgress:setPortionComplete(i, total)
                scanProgress:setCaption(string.format(
                    'Scanning %d / %d photos…', i, total))
                LrTasks.yield()
            end

            local fname = photo:getFormattedMetadata('fileName')
            if fname then
                fname = fname:lower()
                if not byFilename[fname] then byFilename[fname] = {} end
                table.insert(byFilename[fname], {
                    photo = photo,
                    day   = captureDay(photo),
                    ls    = longSide(photo),
                })
            end
        end

        -- ── Step 3: collect suspects ───────────────────────────────────────────
        local suspects      = {}
        local suspectSet    = {}   -- dedup by photo object
        local dupFilenames  = 0
        local reasonDate    = 0
        local reasonSize    = 0

        for _, group in pairs(byFilename) do
            if #group > 1 then
                dupFilenames = dupFilenames + 1

                -- Check whether this group has mixed capture dates
                local firstDay   = group[1].day
                local mixedDates = false
                for j = 2, #group do
                    if group[j].day ~= firstDay then
                        mixedDates = true; break
                    end
                end

                for _, entry in ipairs(group) do
                    local isLowRes   = entry.ls > 0 and entry.ls < LONG_SIDE_THRESHOLD
                    local isSuspect  = mixedDates or isLowRes

                    if isSuspect and not suspectSet[entry.photo] then
                        suspectSet[entry.photo] = true
                        table.insert(suspects, entry.photo)
                        if mixedDates then reasonDate = reasonDate + 1 end
                        if isLowRes   then reasonSize = reasonSize + 1 end
                    end
                end
            end
        end

        scanProgress:done()

        -- ── Step 4: report + confirm ───────────────────────────────────────────
        if #suspects == 0 then
            LrDialogs.message('Suspect Finder',
                string.format(
                    'No suspects found.\n\n'
                 .. 'Scanned %d photos across %d duplicate filename group%s.\n'
                 .. 'All duplicates have matching dates and long side ≥ %d px.',
                    total,
                    dupFilenames, dupFilenames == 1 and '' or 's',
                    LONG_SIDE_THRESHOLD),
                'info')
            return
        end

        -- Build a reason breakdown string
        local reasons = {}
        if reasonDate > 0 then
            reasons[#reasons+1] = string.format(
                '  • %d flagged because their filename group contains mixed capture dates',
                reasonDate)
        end
        if reasonSize > 0 then
            reasons[#reasons+1] = string.format(
                '  • %d flagged because their long side is under %d px (lower-res copy)',
                reasonSize, LONG_SIDE_THRESHOLD)
        end

        local confirmed = LrDialogs.confirm(
            'Suspect Finder',
            string.format(
                'Scan complete — %d suspect photo%s found in %d filename group%s.\n\n'
             .. 'Reasons flagged:\n%s\n\n'
             .. 'Add the keyword  "keyword-suspect"  to all %d photo%s?',
                #suspects, #suspects == 1 and '' or 's',
                dupFilenames, dupFilenames == 1 and '' or 's',
                table.concat(reasons, '\n'),
                #suspects, #suspects == 1 and '' or 's'),
            'Flag Suspects',
            'Cancel')

        if confirmed ~= 'ok' then return end

        -- ── Step 5: write keyword + create smart collection ───────────────────
        local writeProgress = LrProgressScope {
            title = string.format('Flagging %d suspect%s…',
                #suspects, #suspects == 1 and '' or 's'),
        }

        local written        = 0
        local collectionMade = false

        catalog:withWriteAccessDo('Suspect Finder: flag keyword-suspect', function()
            local kwObj = catalog:createKeyword('keyword-suspect', {}, false, nil, true)
            if not kwObj then
                LrDialogs.showError('Could not create keyword "keyword-suspect".')
                return
            end

            for idx, photo in ipairs(suspects) do
                if idx % 50 == 0 then
                    writeProgress:setPortionComplete(idx, #suspects)
                    writeProgress:setCaption(string.format(
                        'Writing %d / %d…', idx, #suspects))
                end
                photo:addKeyword(kwObj)
                written = written + 1
            end

            -- Smart Collection Set + Smart Collection
            local collSet = catalog:createCollectionSet('Suspect Finder', nil, true)
            if collSet then
                catalog:createSmartCollection(
                    'Needs Re-Keywording',
                    {
                        combine = 'intersect',
                        {
                            criteria  = 'keywords',
                            operation = 'words',
                            value     = 'keyword-suspect',
                            value2    = '',
                        },
                    },
                    collSet,
                    true)
                collectionMade = true
            end
        end)

        writeProgress:done()

        -- ── Done ──────────────────────────────────────────────────────────────
        local collectionNote = collectionMade
            and '\n\nSmart Collection  "Suspect Finder → Needs Re-Keywording"\nhas been created in the Collections panel.'
            or  '\n\n(Smart collection could not be created — filter by keyword manually.)'

        LrDialogs.message('Suspect Finder — Done',
            string.format(
                '%d photo%s flagged with  "keyword-suspect".%s\n\n'
             .. 'Next steps:\n'
             .. '  1.  Open  "Suspect Finder → Needs Re-Keywording"  in Collections\n'
             .. '  2.  Select All  (Ctrl+A / Cmd+A)\n'
             .. '  3.  Run  Library → Re-Keyword Selected Photos (Erase & Rebuild)',
                written, written == 1 and '' or 's',
                collectionNote),
            'info')

    end)  -- end startAsyncTask
end)  -- end callWithContext
