--[[
  SuspectFinder.lua — Suspect Finder plugin
  ─────────────────────────────────────────────────────────────────────────────
  Scans the entire catalog and flags lower-resolution duplicates that likely
  received incorrect keywords from a higher-resolution file with the same name.

  A photo is a "suspect" when BOTH conditions are true:
    1.  Its filename (case-insensitive) appears on 2 or more photos in the
        catalog — i.e. there is at least one other file with the same name.
    2.  Its long side (max of width / height, after rotation) is under
        LONG_SIDE_THRESHOLD pixels — i.e. it is the smaller/lower-res copy.

  Flagged photos get the keyword "keyword-suspect".
  After running, filter by that keyword in the Library, select all, and send
  to Keyworder Supreme for a clean re-key.
--]]

local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'
local LrTasks           = import 'LrTasks'

-- ── Config ────────────────────────────────────────────────────────────────────
-- Photos whose long side is strictly below this value AND share a filename
-- with another photo are considered suspects.
local LONG_SIDE_THRESHOLD = 3000   -- pixels

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

        -- ── Step 2: group by filename ──────────────────────────────────────────
        scanProgress:setCaption(string.format('Grouping %d photos by filename…', total))

        local byFilename = {}   -- filename (lower) → { photo, … }

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
                table.insert(byFilename[fname], photo)
            end
        end

        -- ── Step 3: collect suspects ───────────────────────────────────────────
        --   Duplicate filename  AND  long side < LONG_SIDE_THRESHOLD
        local suspects    = {}
        local dupFilenames = 0

        for _, photoList in pairs(byFilename) do
            if #photoList > 1 then
                dupFilenames = dupFilenames + 1
                for _, photo in ipairs(photoList) do
                    local w = photo:getRawMetadata('width')  or 0
                    local h = photo:getRawMetadata('height') or 0
                    -- swap w/h for 90°/270° rotated images
                    local orient = photo:getRawMetadata('orientation') or ''
                    if orient == 'BC' or orient == 'DA' then w, h = h, w end
                    local longSide = math.max(w, h)
                    if longSide > 0 and longSide < LONG_SIDE_THRESHOLD then
                        table.insert(suspects, photo)
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
                 .. 'Scanned %d photos; %d unique filename%s appeared more than once,\n'
                 .. 'but none of those duplicates had a long side under %d px.',
                    total,
                    dupFilenames, dupFilenames == 1 and '' or 's',
                    LONG_SIDE_THRESHOLD),
                'info')
            return
        end

        local confirmed = LrDialogs.confirm(
            'Suspect Finder',
            string.format(
                'Scan complete — %d suspect photo%s found.\n\n'
             .. 'Criteria:\n'
             .. '  • Filename matches at least one other photo in the catalog\n'
             .. '  • Long side is under %d px  (lower-res copy)\n\n'
             .. 'Add the keyword  "keyword-suspect"  to all %d photo%s?',
                #suspects, #suspects == 1 and '' or 's',
                LONG_SIDE_THRESHOLD,
                #suspects, #suspects == 1 and '' or 's'),
            'Flag Suspects',
            'Cancel')

        if confirmed ~= 'ok' then return end

        -- ── Step 5: write keyword ──────────────────────────────────────────────
        local writeProgress = LrProgressScope {
            title = string.format('Flagging %d suspect%s…',
                #suspects, #suspects == 1 and '' or 's'),
        }

        local written         = 0
        local collectionMade  = false

        catalog:withWriteAccessDo('Suspect Finder: flag keyword-suspect', function()
            -- Create (or find) the keyword once, then apply to all suspects
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

            -- ── Smart Collection Set + Smart Collection ────────────────────────
            -- createCollectionSet(name, parent, returnExisting)
            local collSet = catalog:createCollectionSet(
                'Suspect Finder', nil, true)

            -- createSmartCollection(name, searchDesc, parent, returnExisting)
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
                    true)   -- return existing if already present
                collectionMade = true
            end
        end)

        writeProgress:done()

        -- ── Done ──────────────────────────────────────────────────────────────
        local collectionNote = collectionMade
            and '\n\nA Smart Collection  "Suspect Finder → Needs Re-Keywording"\nhas been created in the Collections panel.'
            or  '\n\n(Smart collection could not be created — flag photos manually.)'

        LrDialogs.message('Suspect Finder — Done',
            string.format(
                '%d photo%s flagged with  "keyword-suspect".%s\n\n'
             .. 'Next steps:\n'
             .. '  1.  Open the  "Suspect Finder → Needs Re-Keywording"\n'
             .. '      smart collection in the Collections panel\n'
             .. '  2.  Select All  (Ctrl+A / Cmd+A)\n'
             .. '  3.  Run  Library → Re-Keyword Selected Photos (Erase & Rebuild)',
                written, written == 1 and '' or 's',
                collectionNote),
            'info')

    end)  -- end startAsyncTask
end)  -- end callWithContext
