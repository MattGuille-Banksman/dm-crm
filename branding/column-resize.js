// DM-CRM: drag-to-resize columns on Compose record lists.
//
// Loaded on every web app through a Corteza code snippet (setting
// "code-snippets"). Drag the right edge of a column header to resize it;
// double-click the edge to reset. Widths are remembered per page and column
// in this browser (localStorage).
(function () {
  if (window.__dmcrmColumnResize) return
  window.__dmcrmColumnResize = true

  var TABLE_SELECTOR = 'table[data-test-id="table-record-list"]'
  var STORAGE_KEY = 'dmcrm-column-widths'
  var MIN_WIDTH = 48

  var style = document.createElement('style')
  style.textContent = [
    TABLE_SELECTOR + ' thead th { position: relative; }',
    TABLE_SELECTOR + '.dmcrm-resized th { box-sizing: border-box; }',
    TABLE_SELECTOR + ' .dmcrm-col-handle {',
    '  position: absolute; top: 0; right: -4px; width: 8px; height: 100%;',
    '  cursor: col-resize; z-index: 2; user-select: none;',
    '}',
    TABLE_SELECTOR + ' .dmcrm-col-handle:hover,',
    TABLE_SELECTOR + ' .dmcrm-col-handle.dmcrm-active {',
    '  background: linear-gradient(to right, transparent 3px, var(--primary, #4F46E5) 3px, var(--primary, #4F46E5) 5px, transparent 5px);',
    '}',
    TABLE_SELECTOR + '.dmcrm-resized { table-layout: fixed; }',
    TABLE_SELECTOR + '.dmcrm-resized td { overflow: hidden; text-overflow: ellipsis; }',
    'body.dmcrm-resizing, body.dmcrm-resizing * { cursor: col-resize !important; user-select: none !important; }',
  ].join('\n')
  document.head.appendChild(style)

  function loadWidths () {
    try { return JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}') } catch (e) { return {} }
  }

  function saveWidths (widths) {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(widths)) } catch (e) {}
  }

  function headerCells (table) {
    var row = table.tHead && table.tHead.rows[0]
    return row ? Array.prototype.slice.call(row.cells) : []
  }

  function columnKey (table, th) {
    var tables = Array.prototype.slice.call(document.querySelectorAll(TABLE_SELECTOR))
    var label = (th.textContent || '').trim()
    return location.pathname + '#' + tables.indexOf(table) + ':' + label
  }

  // Fixed table layout needs every column to have an explicit width, so the
  // first resize freezes the current widths of all columns.
  function freeze (table) {
    if (table.classList.contains('dmcrm-resized')) return
    var cells = headerCells(table)
    var widths = cells.map(function (th) { return th.getBoundingClientRect().width })
    cells.forEach(function (th, i) { th.style.width = widths[i] + 'px' })
    table.style.width = widths.reduce(function (a, b) { return a + b }, 0) + 'px'
    table.classList.add('dmcrm-resized')
  }

  // The table width is the sum of the columns' set widths. Rendered widths
  // can't be used: with a fixed layout the old table width would just be
  // shared out again across the columns.
  function syncTableWidth (table) {
    var total = headerCells(table).reduce(function (sum, th) {
      var set = parseFloat(th.style.width)
      return sum + (isNaN(set) ? th.getBoundingClientRect().width : set)
    }, 0)
    table.style.width = total + 'px'
  }

  function applySaved (table) {
    var widths = loadWidths()
    var cells = headerCells(table)
    var any = cells.some(function (th) { return widths[columnKey(table, th)] })
    if (!any) return

    freeze(table)
    cells.forEach(function (th) {
      var w = widths[columnKey(table, th)]
      if (w) th.style.width = w + 'px'
    })
    syncTableWidth(table)
  }

  function startResize (event, table, th, handle) {
    event.preventDefault()
    event.stopPropagation()
    freeze(table)

    var startX = event.clientX
    var startWidth = th.getBoundingClientRect().width
    var rtl = getComputedStyle(table).direction === 'rtl'
    handle.classList.add('dmcrm-active')
    document.body.classList.add('dmcrm-resizing')

    function onMove (e) {
      var delta = (e.clientX - startX) * (rtl ? -1 : 1)
      th.style.width = Math.max(MIN_WIDTH, startWidth + delta) + 'px'
      syncTableWidth(table)
    }

    function onUp () {
      document.removeEventListener('mousemove', onMove)
      document.removeEventListener('mouseup', onUp)
      handle.classList.remove('dmcrm-active')
      document.body.classList.remove('dmcrm-resizing')

      var widths = loadWidths()
      widths[columnKey(table, th)] = Math.round(th.getBoundingClientRect().width)
      saveWidths(widths)
    }

    document.addEventListener('mousemove', onMove)
    document.addEventListener('mouseup', onUp)
  }

  function resetColumn (event, table, th) {
    event.preventDefault()
    event.stopPropagation()
    var widths = loadWidths()
    delete widths[columnKey(table, th)]
    saveWidths(widths)

    var stillResized = headerCells(table).some(function (cell) { return widths[columnKey(table, cell)] })
    if (stillResized) {
      // back to its natural width: measure it without a fixed width
      table.classList.remove('dmcrm-resized')
      th.style.width = ''
      var natural = th.getBoundingClientRect().width
      table.classList.add('dmcrm-resized')
      th.style.width = natural + 'px'
      syncTableWidth(table)
      return
    }

    headerCells(table).forEach(function (cell) { cell.style.width = '' })
    table.style.width = ''
    table.classList.remove('dmcrm-resized')
  }

  function enhance (table) {
    var cells = headerCells(table)
    var added = false

    cells.forEach(function (th) {
      // skip the narrow checkbox / drag-handle columns
      if (!(th.textContent || '').trim()) return
      if (th.querySelector(':scope > .dmcrm-col-handle')) return

      var handle = document.createElement('span')
      handle.className = 'dmcrm-col-handle'
      handle.title = 'Drag to resize, double-click to reset'
      th.appendChild(handle)
      added = true
    })

    if (added) applySaved(table)
  }

  // One delegated listener per event (capture phase) instead of listeners on
  // each handle: the tables are re-rendered often, and this way a handle
  // always works and header clicks (sorting) never fire while resizing.
  function handleOf (event) {
    var handle = event.target && event.target.closest && event.target.closest('.dmcrm-col-handle')
    if (!handle) return null
    var th = handle.parentElement
    var table = th && th.closest(TABLE_SELECTOR)
    return table ? { handle: handle, th: th, table: table } : null
  }

  document.addEventListener('mousedown', function (e) {
    var h = handleOf(e)
    if (h && e.button === 0) startResize(e, h.table, h.th, h.handle)
  }, true)

  document.addEventListener('dblclick', function (e) {
    var h = handleOf(e)
    if (h) resetColumn(e, h.table, h.th)
  }, true)

  document.addEventListener('click', function (e) {
    if (handleOf(e)) { e.preventDefault(); e.stopPropagation() }
  }, true)

  var scheduled = false
  function scan () {
    scheduled = false
    Array.prototype.forEach.call(document.querySelectorAll(TABLE_SELECTOR), enhance)
  }

  new MutationObserver(function () {
    if (scheduled) return
    scheduled = true
    window.requestAnimationFrame(scan)
  }).observe(document.documentElement, { childList: true, subtree: true })

  scan()
})()
