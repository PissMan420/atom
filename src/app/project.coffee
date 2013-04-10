fsUtils = require 'fs-utils'
_ = require 'underscore'
$ = require 'jquery'
Range = require 'range'
Buffer = require 'text-buffer'
EditSession = require 'edit-session'
ImageEditSession = require 'image-edit-session'
EventEmitter = require 'event-emitter'
Directory = require 'directory'
BufferedProcess = require 'buffered-process'

# Public: Represents a project that's opened in Atom.
#
# Ultimately, a project is a git directory that's been opened. It's a collection
# of directories and files that you can operate on.
module.exports =
class Project
  registerDeserializer(this)

  @deserialize: (state) ->
    new Project(state.path)

  tabLength: 2
  softTabs: true
  softWrap: false
  rootDirectory: null
  editSessions: null
  ignoredPathRegexes: null

  constructor: (path) ->
    @setPath(path)
    @editSessions = []
    @buffers = []

  serialize: ->
    deserializer: 'Project'
    path: @getPath()

  destroy: ->
    editSession.destroy() for editSession in @getEditSessions()

  # Public: Retrieves the project path.
  #
  # Returns a {String}.
  getPath: ->
    @rootDirectory?.path

  # Public: Sets the project path.
  #
  # path - A {String} representing the new path
  setPath: (path) ->
    @rootDirectory?.off()

    if path?
      directory = if fsUtils.isDirectory(path) then path else fsUtils.directory(path)
      @rootDirectory = new Directory(directory)
    else
      @rootDirectory = null

    @trigger "path-changed"

  # Public: Retrieves the name of the root directory.
  #
  # Returns a {String}.
  getRootDirectory: ->
    @rootDirectory

  # Public: Retrieves the names of every file (that's not `git ignore`d) in the project.
  #
  # Returns an {Array} of {String}s.
  getFilePaths: ->
    deferred = $.Deferred()
    paths = []
    onFile = (path) => paths.push(path) unless @isPathIgnored(path)
    onDirectory = -> true
    fsUtils.traverseTreeSync(@getPath(), onFile, onDirectory)
    deferred.resolve(paths)
    deferred.promise()

  # Public: Identifies if a path is ignored.
  #
  # path - The {String} name of the path to check
  #
  # Returns a {Boolean}.
  isPathIgnored: (path) ->
    for segment in path.split("/")
      ignoredNames = config.get("core.ignoredNames") or []
      return true if _.contains(ignoredNames, segment)

    @ignoreRepositoryPath(path)

  # Public: Identifies if a path is ignored.
  #
  # path - The {String} name of the path to check
  #
  # Returns a {Boolean}.
  ignoreRepositoryPath: (path) ->
    config.get("core.hideGitIgnoredFiles") and git?.isPathIgnored(fsUtils.join(@getPath(), path))

  resolve: (filePath) ->
    filePath = fsUtils.join(@getPath(), filePath) unless filePath[0] == '/'
    fsUtils.absolute filePath

  relativize: (fullPath) ->
    return fullPath unless fullPath.lastIndexOf(@getPath()) is 0
    fullPath.replace(@getPath(), "").replace(/^\//, '')

  getSoftTabs: -> @softTabs
  setSoftTabs: (@softTabs) ->

  getSoftWrap: -> @softWrap
  setSoftWrap: (@softWrap) ->

  buildEditSession: (filePath, editSessionOptions={}) ->
    if ImageEditSession.canOpen(filePath)
      new ImageEditSession(filePath)
    else
      @buildEditSessionForBuffer(@bufferForPath(filePath), editSessionOptions)

  buildEditSessionForBuffer: (buffer, editSessionOptions) ->
    options = _.extend(@defaultEditSessionOptions(), editSessionOptions)
    options.project = this
    options.buffer = buffer
    editSession = new EditSession(options)
    @editSessions.push editSession
    @trigger 'edit-session-created', editSession
    editSession

  defaultEditSessionOptions: ->
    tabLength: @tabLength
    softTabs: @getSoftTabs()
    softWrap: @getSoftWrap()

  getEditSessions: ->
    new Array(@editSessions...)

  eachEditSession: (callback) ->
    callback(editSession) for editSession in @getEditSessions()
    @on 'edit-session-created', (editSession) -> callback(editSession)

  removeEditSession: (editSession) ->
    _.remove(@editSessions, editSession)

  getBuffers: ->
    buffers = []
    for editSession in @editSessions when not _.include(buffers, editSession.buffer)
      buffers.push editSession.buffer
    buffers

  eachBuffer: (args...) ->
    subscriber = args.shift() if args.length > 1
    callback = args.shift()

    callback(buffer) for buffer in @getBuffers()
    if subscriber
      subscriber.subscribe this, 'buffer-created', (buffer) -> callback(buffer)
    else
      @on 'buffer-created', (buffer) -> callback(buffer)

  bufferForPath: (filePath, text) ->
    if filePath?
      filePath = @resolve(filePath)
      if filePath
        buffer = _.find @buffers, (buffer) -> buffer.getPath() == filePath
        buffer or @buildBuffer(filePath, text)
    else
      @buildBuffer(null, text)

  buildBuffer: (filePath, text) ->
    buffer = new Buffer(filePath, text)
    @buffers.push buffer
    @trigger 'buffer-created', buffer
    buffer

  removeBuffer: (buffer) ->
    _.remove(@buffers, buffer)

  scan: (regex, iterator) ->
    bufferedData = ""
    state = 'readingPath'
    path = null

    readPath = (line) ->
      if /^[0-9,; ]+:/.test(line)
        state = 'readingLines'
      else if /^:/.test line
        path = line.substr(1)
      else
        path += ('\n' + line)

    readLine = (line) ->
      if line.length == 0
        state = 'readingPath'
        path = null
      else
        colonIndex = line.indexOf(':')
        matchInfo = line.substring(0, colonIndex)
        lineText = line.substring(colonIndex + 1)
        readMatches(matchInfo, lineText)

    readMatches = (matchInfo, lineText) ->
      [lineNumber, matchPositionsText] = matchInfo.match(/(\d+);(.+)/)[1..]
      row = parseInt(lineNumber) - 1
      matchPositions = matchPositionsText.split(',').map (positionText) -> positionText.split(' ').map (pos) -> parseInt(pos)

      for [column, length] in matchPositions
        range = new Range([row, column], [row, column + length])
        match = lineText.substr(column, length)
        iterator({path, range, match})

    deferred = $.Deferred()
    exit = (code) ->
      if code is -1
        deferred.reject({command, code})
      else
        deferred.resolve()
    stdout = (data) ->
      lines = data.split('\n')
      lines.pop() # the last segment is a spurious '' because data always ends in \n due to bufferLines: true
      for line in lines
        readPath(line) if state is 'readingPath'
        readLine(line) if state is 'readingLines'

    command = require.resolve('nak')
    args = ['--ackmate', regex.source, @getPath()]
    args.unshift("--addVCSIgnores") if config.get('core.excludeVcsIgnoredPaths')
    new BufferedProcess({command, args, stdout, exit})
    deferred

_.extend Project.prototype, EventEmitter
