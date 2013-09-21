fs = require 'fs'
path = require 'path'
util = require 'util'
_ = require 'underscore'
Canvas = require 'canvas'


#
# Drawing
#

Context =
  canvas: null
  ctx: null

erase_background = ->
  {canvas, ctx} = Context
  ctx.fillStyle = 'white'
  ctx.fillRect 0, 0, canvas.width, canvas.height

measure_text = (text, {font}={}) ->
  ctx = Context.ctx
  ctx.font = font if font
  ctx.measureText text

drawText = (text, options={}) ->
  ctx = Context.ctx
  options = text if _.isObject text
  {font, fillStyle, x, y, gravity, width} = options
  gravity ||= ''
  if options.choices
    for choice in options.choices
      text = choice if _.isString choice
      {font} = choice if _.isObject choice
      break if measure_text(text, font: font).width <= options.width
  ctx.font = font if font
  ctx.fillStyle = fillStyle if fillStyle
  m = ctx.measureText text
  x ||= 0
  y ||= 0
  x -= m.width / 2 if gravity.match(/^(top|center|middle|centerbottom)$/i)
  x -= m.width if gravity.match(/^(right|topRight|botRight)$/i)
  y -= m.emHeightDescent if gravity.match(/^(bottom|botLeft|botRight)$/i)
  y += m.emHeightAscent if gravity.match(/^(top|topLeft|topRight)$/i)
  ctx.fillText text, x, y

withCanvas = (canvas, cb) ->
  savedCanvas = Context.canvas
  savedContext = Context.context
  try
    Context.canvas = canvas
    Context.ctx = canvas.getContext('2d')
    return cb()
  finally
    Context.canvas = savedCanvas
    Context.context = savedContext

withGraphicsContext = (fn) ->
  ctx = Context.ctx
  ctx.save()
  try
    fn ctx
  finally
    ctx.restore()


#
# Box-based Declarative Layout
#

box = (params) ->
  box = _.extend {width: 0}, params
  box.height ?= (box.ascent ? 0) + (box.descent ? 0)
  box.ascent ?= box.height - (box.descent ? 0)
  box.descent ?= box.height - box.ascent
  box

padBox = (box, options) ->
  box.height += options.bottom if options.bottom
  box.descent = ((box.descent ? 0) + options.bottom) if options.bottom
  box

textBox = (text, options) ->
  options = _.extend {}, options, gravity: false
  measure = measure_text text, options
  box
    width: measure.width
    height: measure.emHeightAscent + measure.emHeightDescent
    descent: measure.emHeightDescent
    draw: -> drawText text, options

vbox = (boxes...) ->
  options = {}
  options = boxes.pop() unless boxes[boxes.length - 1].width?
  options = _.extend {align: 'left'}, options
  width = Math.max _.pluck(boxes, 'width')...
  height = _.pluck(boxes, 'height').reduce (a, b) -> a + b
  descent = boxes[boxes.length - 1].descent
  if options.baseline
    boxes_below = boxes[boxes.indexOf(options.baseline)+1...]
    descent = options.baseline.descent + _.pluck(boxes_below, 'height').reduce ((a, b) -> a + b), 0
  box
    width: width
    height: height
    descent: descent
    draw: ->
      dy = -height
      boxes.forEach (b1) ->
        withGraphicsContext (ctx) ->
          dx = switch options.align
            when 'left' then 0
            when 'center' then Math.max 0, (width - b1.width) / 2
          ctx.translate dx, dy + b1.height - b1.descent
          b1.draw?(ctx)
          dy += b1.height

above = vbox

hbox = (b1, b2) ->
  container_size = CurrentBook?.page_options or CurrentPage
  boxes = [b1, b2]
  height = Math.max _.pluck(boxes, 'height')...
  width = _.pluck(boxes, 'width').reduce (a, b) -> a + b
  width = container_size.width if width == Infinity
  spring_count = (b for b in boxes when b.width == Infinity).length
  box
    width: width
    height: height
    draw: ->
      x = 0
      boxes.forEach (b) ->
        withGraphicsContext (ctx) ->
          ctx.translate x, 0
          b.draw?(ctx)
        if b.width == Infinity
          x += (width - (width for {width} in boxes when width != Infinity).reduce (a, b) -> a + b) / spring_count
        else
          x += b.width

overlay = (boxes...) ->
  box
    width: Math.max _.pluck(boxes, 'width')...
    height: Math.max _.pluck(boxes, 'height')...
    draw: ->
      for b in boxes
        withGraphicsContext (ctx) ->
          b.draw ctx

labeled = (text, options, box) ->
  [options, box] = [{}, options] if arguments.length == 2
  default_options =
    font: '12px Times'
    fillStyle: 'black'
  options = _.extend default_options, options
  above textBox(text, options), box, options

withGridBoxes = (options, generator) ->
  {max, floor} = Math

  options = _.extend {header_height: 0, gutter_width: 10, gutter_height: 10}, options
  container_size = CurrentBook?.page_options or CurrentPage

  line_break = {width: 0, height: 0, linebreak: true}
  header = null
  cells = []
  generator
    header: (box) -> header = box
    startRow: () -> cells.push line_break
    cell: (box) -> cells.push box
    cells: (boxes) -> cells.push b for b in boxes

  cell_width = max _.pluck(cells, 'width')...
  cell_height = max _.pluck(cells, 'height')...
  # cell.descent ?= 0 for cell in cells

  _.extend options
    , header_height: header?.height or 0
    , cell_width: cell_width
    , cell_height: cell_height
    , cols: max 1, floor((container_size.width + options.gutter_width) / (cell_width + options.gutter_width))
  options.rows = do ->
    content_height = container_size.height - options.header_height
    cell_height = cell_height + options.gutter_height
    max 1, floor((content_height + options.gutter_height) / cell_height)

  cell.descent ?= 0 for cell in cells
  max_descent = max _.pluck(cells, 'descent')...
  # console.info 'descent', max_descent, 'from', _.pluck(cells, 'descent')

  withGrid options, (grid) ->
    if header
      withGraphicsContext (ctx) ->
        ctx.translate 0, header.height - header.descent
        header?.draw ctx
    cells.forEach (cell) ->
      grid.startRow() if cell.linebreak?
      return if cell == line_break
      grid.add_cell ->
        withGraphicsContext (ctx) ->
          ctx.translate 0, cell_height - cell.descent
          cell.draw ctx


#
# File Saving
#

BuildDirectory = '.'
DefaultFilename = null

directory = (path) -> BuildDirectory = path
filename = (name) -> DefaultFilename = name

save_canvas_to_png = (canvas, fname) ->
  out = fs.createWriteStream(path.join(BuildDirectory, fname))
  stream = canvas.pngStream()
  stream.on 'data', (chunk) -> out.write(chunk)
  stream.on 'end', () -> console.info "Saved #{fname}"


#
# Paper Sizes
#

PaperSizes =
  folio: '12in x 15in'
  quarto: '9.5in x 12in'
  octavo: '6in x 9in'
  duodecimo: '5in x 7.375in'
  # ANSI sizes
  'ANSI A': '8.5in × 11in'
  'ANSI B': '11in x 17in'
  letter: 'ANSI A'
  ledger: 'ANSI B landscape'
  tabloid: 'ANSI B portrait'
  'ANSI C': '17in × 22in'
  'ANSI D': '22in × 34in'
  'ANSI E': '34in × 44in'

get_page_size_dimensions = (size, orientation=null) ->
  parseMeasure = (measure) ->
    return measure if typeof measure == 'number'
    unless measure.match /^(\d+(?:\.\d*)?)\s*(.+)$/
      throw new Error "Unrecognized measure #{util.inspect measure} in #{util.inspect size}"
    [n, units] = [Number(RegExp.$1), RegExp.$2]
    switch units
      when "" then n
      when "in" then n * 72
      else throw new Error "Unrecognized units #{util.inspect units} in #{util.inspect size}"

  {width, height} = size
  while _.isString(size)
    [size, orientation] = [RegExp.$1, RegExp.R2] if size.match /^(.+)\s+(landscape|portrait)$/
    break unless size of PaperSizes
    size = PaperSizes[size]
    {width, height} = size
  if _.isString(size)
    throw new Error "Unrecognized book size format #{util.inspect size}" unless size.match /^(.+?)\s*[x×]\s*(.+)$/
    [width, height] = [RegExp.$1, RegExp.$2]

  [width, height] = [parseMeasure(width), parseMeasure(height)]
  switch orientation or ''
    when 'landscape' then [width, height] = [height, width] unless width > height
    when 'portrait' then [width, height] = [height, width] if width > height
    when '' then null
    else throw new Error "Unknown orientation #{util.inspect orientation}"
  {width, height}

do ->
  for name, value of PaperSizes
    PaperSizes[name] = get_page_size_dimensions value


#
# Layout
#

CurrentPage = null
CurrentBook = null
Mode = null

_.mixin
  sum:
    do (plus=(a,b) -> a+b) ->
      (xs) -> _.reduce(xs, plus, 0)

TDLRLayout = (boxes) ->
  page_width = CurrentPage.width - CurrentPage.left_margin - CurrentPage.top_margin
  boxes = boxes[..]
  b.descent ?= 0 for b in boxes
  dy = 0
  width = 0
  while boxes.length
    console.info 'next', boxes.length
    line = []
    while boxes.length
      b = boxes[0]
      break if width + b.width > page_width and line.length > 0
      line.push b
      boxes.shift()
      width += b.width
    ascent = _.max(b.height - b.descent for b in line)
    descent = _.chain(line).pluck('descent').max()
    dx = 0
    console.info 'draw', line.length
    for b in line
      withGraphicsContext (ctx) ->
        ctx.translate dx, dy + ascent
        console.info 'draw', dx, dy + ascent, b.draw
        b.draw ctx
      dx += b.width
    dy += ascent + descent

withPage = (options, draw_page) ->
  throw new Error "Already inside a page" if CurrentPage
  defaults = {width: 100, height: 100, page_margin: 10}
  {width, height, page_margin} = _.extend defaults, options
  {left_margin, top_margin, right_margin, bottom_margin} = options
  left_margin ?= page_margin
  top_margin ?= page_margin
  right_margin ?= page_margin
  bottom_margin ?= page_margin

  canvas = Context.canvas ||=
    new Canvas width + left_margin + right_margin, height + top_margin + bottom_margin, Mode
  ctx = Context.ctx = canvas.getContext('2d')
  ctx.textDrawingMode = 'glyph' if Mode == 'pdf'
  boxes = []

  try
    page =
      left_margin: left_margin
      top_margin: top_margin
      right_margin: right_margin
      bottom_margin: bottom_margin
      width: canvas.width
      height: canvas.height
      context: ctx
      box: (options) ->
        boxes.push box(options)
    CurrentPage = page

    erase_background()

    withGraphicsContext (ctx) ->
      ctx.translate left_margin, bottom_margin
      CurrentBook?.header? page
      CurrentBook?.footer? page
      draw_page? page
      TDLRLayout boxes

    switch Mode
      when 'pdf' then ctx.addPage()
      else
        filename = "#{DefaultFilename or 'test'}.png"
        fs.writeFile path.join(BuildDirectory, filename), canvas.toBuffer()
        console.info "Saved #{filename}"
  finally
    CurrentPage = null

withGrid = (options, cb) ->
  defaults = {gutter_width: 10, gutter_height: 10, header_height: 0}
  options = _.extend defaults, options
  {cols, rows, cell_width, cell_height, header_height, gutter_width, gutter_height} = options
  options.width ||= cols * cell_width + (cols - 1) * gutter_width
  options.height ||=  header_height + rows * cell_height + (rows - 1) * gutter_height
  overflow = []
  withPage options, (page) ->
    cb
      context: page.context
      rows: rows
      cols: cols
      row: 0
      col: 0
      add_cell: (draw_fn) ->
        [col, row] = [@col, @row]
        if row >= rows
          overflow.push {col, row, draw_fn}
        else
          withGraphicsContext (ctx) ->
            ctx.translate col * (cell_width + gutter_width), header_height + row * (cell_height + gutter_height)
            draw_fn()
        col += 1
        [col, row] = [0, row + 1] if col >= cols
        [@col, @row] = [col, row]
      startRow: ->
        [@col, @row] = [0, @row + 1] if @col > 0
  while overflow.length
    cell.row -= rows for cell in overflow
    withPage options, (page) ->
      for {col, row, draw_fn} in _.select(overflow, (cell) -> cell.row < rows)
        withGraphicsContext (ctx) ->
          ctx.translate col * (cell_width + gutter_width), header_height + row * (cell_height + gutter_height)
          draw_fn()
    overflow = (cell for cell in overflow when cell.row >= rows)

withBook = (filename, options, cb) ->
  throw new Error "withBook called recursively" if CurrentBook
  [options, cb] = [{}, options] if _.isFunction(options)
  page_limit = options.page_limit
  page_count = 0

  try
    book =
      page_options: {}

    Mode = 'pdf'
    CurrentBook = book

    size = options.size
    if size
      {width, height} = get_page_size_dimensions size
      _.extend book.page_options, {width, height}
      canvas = Context.canvas ||= new Canvas width, height, Mode
      ctx = Context.ctx = canvas.getContext '2d'
      ctx.textDrawingMode = 'glyph' if Mode == 'pdf'

    cb
      page_header: (header) -> book.header = header
      page_footer: (footer) -> book.footer = footer
      withPage: (options, draw_page) ->
        [options, draw_page] = [{}, options] if _.isFunction(options)
        return if @done
        options = _.extend {}, book.page_options, options
        page_count += 1
        if CurrentPage
          draw_page CurrentPage
        else
          withPage options, draw_page
        @done = true if page_limit and page_limit <= page_count

    if canvas
      write_pdf canvas, path.join(BuildDirectory, "#{filename}.pdf")
    else
      console.warn "No pages"
  finally
    CurrentBook = null
    Mode = null
    canvas = null
    ctx = null

write_pdf = (canvas, pathname) ->
  fs.writeFile pathname, canvas.toBuffer(), (err) ->
    if err
      console.error "Error #{err.code} writing to #{err.path}"
    else
      console.info "Saved #{pathname}"

module.exports = {
  PaperSizes
  above
  withBook
  withGrid
  withGridBoxes

  drawText
  box
  hbox

  textBox
  labeled
  measure_text
  directory
  filename
  withGraphicsContext
  withCanvas
}
