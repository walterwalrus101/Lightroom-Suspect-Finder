--[[
  SuspectFinder.lua — Suspect Finder plugin
  ─────────────────────────────────────────────────────────────────────────────
  Scans the entire catalog and flags photos that likely received incorrect
  keywords copied from a different file that happened to share the same name.

  A photo is a "suspect" when BOTH conditions are true:
    1.  Its filename (case-insensitive) appears on 2 or more photos in the
        catalog — i.e. there is at least one other file with the same name.
    2.  The group contains photos with different capture dates — meaning these
        are genuinely different images that share a filename by coincidence and
        may have had each other's keywords applied incorrectly.

  ALL photos in a mixed-date group are flagged (not just the lower-res ones),
  because any of them could be carrying the wrong keywords.

  Flagged photos get the keyword "keyword-suspect".
  A Smart Collection "Suspect Finder → Needs Re-Keywording" is created
  automatically so you can select all suspects in one click and send them to
  Keyworder Supreme for a clean re-key.
--]]

local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'
local LrTasks           = import 'LrTasks'

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Returns capture date truncated to whole-day granularity, or nil.
-- Day-level avoids false positives from edited copies with slightly
-- different timestamps.
local function captureDay(photo)
    local dt = photo:getRawMetadata('dateTimeOriginal')
    if type(dt) == 'number' and dt > 0 then
        return math.floor(dt / 86400)
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

        -- ── Step 2: group by filename, collecting capture date per photo ───────
        local byFilename = {}   -- filename (lower) → { { photo, day }, … }

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
                })
            end
        end

        -- ── Step 3: collect suspects ───────────────────────────────────────────
        -- Flag every photo in a group where the capture dates are not all the same.
        local suspects     = {}
        local dupFilenames = 0   -- groups with 2+ photos
        local mixedGroups  = 0   -- groups that have mixed dates

        for _, group in pairs(byFilename) do
            if #group > 1 then
                dupFilenames = dupFilenames + 1

                local firstDay   = group[1].day
                local mixedDates = false
                for j = 2, #group do
                    if group[j].day ~= firstDay then
                        mixedDates = true; break
                    end
                end

                if mixedDates then
                    mixedGroups = mixedGroups + 1
                    for _, entry in ipairs(group) do
                        table.insert(suspects, entry.photo)
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
                 .. 'Scanned %d photos; %d filename group%s had duplicate names,\n'
                 .. 'but all duplicates share the same capture date.',
                    total,
                    dupFilenames, dupFilenames == 1 and '' or 's'),
                'info')
            return
        end

        local confirmed = LrDialogs.confirm(
            'Suspect Finder',
            string.format(
                'Scan complete — %d suspect photo%s found.\n\n'
             .. '%d filename group%s contain the same filename but different\n'
             .. 'capture dates, meaning these are different images that may\n'
             .. 'have received each other\'s keywords.\n\n'
             .. 'Add the keyword  "keyword-suspect"  to all %d photo%s?',
                #suspects, #suspects == 1 and '' or 's',
                mixedGroups, mixedGroups == 1 and '' or 's',
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
