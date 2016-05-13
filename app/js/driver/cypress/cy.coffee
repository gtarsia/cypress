$Cypress.Cy = do ($Cypress, _, Backbone, Promise) ->

  class $Cy
    ## does this need to be moved
    ## to an instance property?
    sync: {}

    constructor: (@Cypress, specWindow) ->
      @defaults()
      @listeners()

      @commands = $Cypress.Commands.create()
      @privates = {}

      specWindow.cy = @

    initialize: (obj) ->
      @defaults()

      {$remoteIframe} = obj

      @private("$remoteIframe", $remoteIframe)

      @_setRemoteIframeProps($remoteIframe)

      $remoteIframe.on "load", =>
        @_setRemoteIframeProps($remoteIframe)

        @urlChanged(null, {log: false})
        @pageLoading(false)

        ## we reapply window listeners on load even though we
        ## applied them already during onBeforeLoad. the reason
        ## is that after load javascript has finished being evaluated
        ## and we may need to override things like alert + confirm again
        @bindWindowListeners @private("window")
        @isReady(true, "load")
        @Cypress.trigger("load")

      ## anytime initialize is called we immediately
      ## set cy to be ready to invoke commands
      ## this prevents a bug where we go into not
      ## ready mode due to the unload event when
      ## our tests are re-run
      @isReady(true, "initialize")

    defaults: ->
      @props = {}

      return @

    silenceConsole: (contentWindow) ->
      if c = contentWindow.console
        c.log = ->
        c.warn = ->
        c.info = ->

    listeners: ->
      @listenTo @Cypress, "initialize", (obj) =>
        @initialize(obj)

      ## why arent we listening to "defaults" here?
      ## instead we are manually hard coding them
      @listenTo @Cypress, "stop",       => @stop()
      @listenTo @Cypress, "restore",    => @restore()
      @listenTo @Cypress, "abort",      => @abort()
      @listenTo @Cypress, "test:after:hooks", (test) => @checkTestErr(test)

    abort: ->
      @offWindowListeners()
      @offIframeListeners(@private("$remoteIframe"))
      @isReady(false, "abort")
      @private("runnable")?.clearTimeout()

      promise = @prop("promise")
      promise?.cancel()

      ## ready can potentially be cancellable
      ## so we need cancel it (if it is)
      ready = @prop("ready")
      if ready and readyPromise = ready.promise
        if readyPromise.isCancellable()
          readyPromise.cancel()

      Promise.resolve(promise)

    stop: ->
      delete window.cy

      @stopListening()

      @offWindowListeners()
      @offIframeListeners(@private("$remoteIframe"))

      @privates = {}

      @Cypress.cy = null

    restore: ->
      ## if our index is above 0 but is below the commands.length
      ## then we know we've ended early due to a done() and
      ## we should throw a very specific error message
      index = @prop("index")
      if index > 0 and index < @commands.length
        @endedEarlyErr(index)

      @clearTimeout @prop("runId")
      @clearTimeout @prop("timerId")

      ## reset the commands to an empty array
      ## by mutating it. we do this because
      ## commands is the context in promises
      ## which ends up holding a reference
      ## to the old array and keeps objects
      ## in memory longer than we want them
      @commands.reset()

      ## remove any event listeners
      @off()

      ## removes any registered props from the
      ## instance
      @defaults()

      return @

    ## global options applicable to all cy instances
    ## and restores
    options: (options = {}) ->

    nullSubject: ->
      @prop("subject", null)

      return @

    _eventHasReturnValue: (e) ->
      val = e.originalEvent.returnValue

      ## return false if val is an empty string
      ## of if its undinefed
      return false if val is "" or _.isUndefined(val)

      ## else return true
      return true

    isReady: (bool = true, event) ->
      if bool
        ## we set recentlyReady to true
        ## so we dont accidently set isReady
        ## back to false in between commands
        ## which are async
        @prop("recentlyReady", true)

        if ready = @prop("ready")
          if ready.promise.isPending()
            ready.promise.then =>
              @trigger "ready", true

              ## prevent accidential chaining
              ## .this after isReady resolves
              return null

        return ready?.resolve()

      ## if we already have a ready object and
      ## its state is pending just leave it be
      ## and dont touch it
      return if @prop("ready") and @prop("ready").promise.isPending()

      ## else set it to a deferred object
      @trigger "ready", false

      @prop "ready", Promise.pending()

    run: ->
      ## start at 0 index if we dont have one
      index = @prop("index") ? @prop("index", 0)

      command = @commands.at(index)

      ## if the command should be skipped
      ## just bail and increment index
      ## and set the subject
      ## TODO DRY THIS LOGIC UP
      if command and command.get("skip")
        ## must set prev + next since other
        ## operations depend on this state being correct
        command.set({prev: @commands.at(index - 1), next: @commands.at(index + 1)})
        @prop("index", index + 1)
        @prop("subject", command.get("subject"))
        return @run()

      runnable = @private("runnable")

      ## if we're at the very end
      if not command

        ## trigger end event
        @trigger("end")

        ## and we should have a next property which
        ## holds mocha's .then callback fn
        if next = @prop("next")
          next()
          @prop("next", null)

        return @

      ## store the previous timeout
      prevTimeout = @_timeout()

      ## prior to running set the runnables
      ## timeout to 30s. this is useful
      ## because we may have to wait to begin
      ## running such as the case in angular
      @_timeout(30000)

      run = =>
        ## bail if we've changed runnables by the
        ## time this resolves
        return if @private("runnable") isnt runnable

        ## reset the timeout to what it used to be
        @_timeout(prevTimeout)

        @trigger "command:start", command

        promise = @set(command, @commands.at(index - 1), @commands.at(index + 1)).then =>
          ## each successful command invocation should
          ## always reset the timeout for the current runnable
          ## unless it already has a state.  if it has a state
          ## and we reset the timeout again, it will always
          ## cause a timeout later no matter what.  by this time
          ## mocha expects the test to be done
          @_timeout(prevTimeout) if not runnable.state

          ## mutate index by incrementing it
          ## this allows us to keep the proper index
          ## in between different hooks like before + beforeEach
          ## else run will be called again and index would start
          ## over at 0
          @prop("index", index += 1)

          @trigger "command:end", command

          if fn = @prop("onPaused")
            fn.call(@, @run)
          else
            @defer @run

          ## must have this empty return here else we end up creating
          ## additional .then callbacks due to bluebird chaining
          return null

        .catch Promise.CancellationError, (err) =>
          @cancel(err)

          ## need to signify we're done our promise here
          ## so we cannot chain off of it, or have bluebird
          ## accidentally chain off of the return value
          return err

        .catch (err) =>
          @fail(err)

          ## reset the nestedIndex back to null
          @prop("nestedIndex", null)

          ## also reset recentlyReady back to null
          @prop("recentlyReady", null)

          return err
        ## signify we are at the end of the chain and do not
        ## continue chaining anymore
        # promise.done()

        @prop "promise", promise

        @trigger "set", command

      ## automatically defer running each command in succession
      ## so each command is async
      @defer(run)

    clearTimeout: (id) ->
      clearImmediate(id) if id
      return @

    # get: (name) ->
    #   alias = @aliases[name]
    #   return alias unless _.isUndefined(alias)

    #   ## instead of returning a function here and setting this
    #   ## invoke property, we should just convert this to a deferred
    #   ## and then during the actual save we should find out anystanding
    #   ## 'get' promises that match the name and then resolve them.
    #   ## the problem with this is we still need to run this anonymous
    #   ## function to check to see if we have an alias by that name
    #   ## else our alias will never resolve (if save is never called
    #   ## by this name argument)
    #   fn = =>
    #     @aliases[name] or
    #       ## TODO: update this if this code gets uncommented
    #       @throwErr("No alias was found by the name: #{name}")
    #   fn._invokeImmediately = true
    #   fn

    set: (command, prev, next) ->
      command.set({prev: prev, next: next})

      @prop("current", command)

      @invoke2(command)

    invoke2: (command, args...) ->
      promise = if @prop("ready")
        Promise.resolve @prop("ready").promise
      else
        Promise.resolve()

      promise.cancellable().then =>
        @trigger "invoke:start", command

        @prop "nestedIndex", @prop("index")

        ## allow the invoked arguments to be overridden by
        ## passing them in explicitly
        ## else just use the arguments the command was
        ## originally created with
        return if args.length then args else command.get("args")

      ## allow promises to be used in the arguments
      ## and wait until they're all resolved
      .all(args)

      .then (args) =>
        ## if the first argument is a function and it has an _invokeImmediately
        ## property that means we are supposed to immediately invoke
        ## it and use its return value as the argument to our
        ## current command object
        if _.isFunction(args[0]) and args[0]._invokeImmediately
          args[0] = args[0].call(@)

        ## rewrap all functions by checking
        ## the chainer id before running its fn
        @_checkForNewChain command.get("chainerId")

        ## run the command's fn
        ret = command.get("fn").apply(command.get("ctx"), args)

        ## allow us to immediately tap into
        ## return value of our command
        @trigger "command:returned:value", command, ret

        ## we cannot pass our cypress instance or our chainer
        ## back into bluebird else it will create a thenable
        ## which is never resolved
        if (ret is @ or ret is @chain()) then null else ret

      .then (subject) =>
        ## if ret is a DOM element and its not an instance of our jQuery
        if subject and Cypress.Utils.hasElement(subject) and not Cypress.Utils.isInstanceOf(subject, $)
          ## set it back to our own jquery object
          ## to prevent it from being passed downstream
          subject = @$$(subject)

        command.set({subject: subject})

        ## end / snapshot our logs
        ## if they need it
        command.finishLogs()

        ## trigger an event here so we know our
        ## command has been successfully applied
        ## and we've potentially altered the subject
        @trigger "invoke:subject", subject, command

        ## reset the nestedIndex back to null
        @prop("nestedIndex", null)

        ## also reset recentlyReady back to null
        @prop("recentlyReady", null)

        @prop("subject", subject)

        @trigger "invoke:end", command

        ## we must look back at the ready property
        ## at the end of resolving our command because
        ## its possible it has become "unready" such
        ## as beforeunload firing. in that case before
        ## resolving we need to ensure it finishes first
        if ready = @prop("ready")
          if ready.promise.isPending()
            return ready.promise
            .then =>
              ## if we became unready when a command
              ## was being resolved then we need to
              ## null out the subject here and additionally
              ## check for child commands and error if found
              ## only if this is a DOM subject
              ##
              ## since we delay the resolving
              ## of our command subjects, they may have
              ## caused a page load / form submit so
              ## if our subject has been nulled we need
              ## to keep it nulled
              if @prop("pageChangeEvent")
                @prop("pageChangeEvent", false)

                ## if we currently have a DOM subject and its not longer
                ## in the document then we need to null out our subject because
                ## a page change has happened and we want to discontinue chaining
                if $Cypress.Utils.hasElement(subject) and not @_contains(subject)
                  ## additionally check for errors here
                  ## so we can notify the user if they're trying
                  ## to chain child commands off of this null subject
                  @nullSubject()

                return @prop("subject")
            .catch (err) ->

        return @prop("subject")

    cancel: (err) ->
      @trigger "cancel", @prop("current")

    enqueue: (key, fn, args, type, chainerId) ->
      @clearTimeout @prop("runId")

      obj = {name: key, ctx: @, fn: fn, args: args, type: type, chainerId: chainerId}

      @trigger "enqueue", obj
      @Cypress.trigger "enqueue", obj

      @insertCommand(obj)

    insertCommand: (obj) ->
      ## if we have a nestedIndex it means we're processing
      ## nested commands and need to splice them into the
      ## index past the current index as opposed to
      ## pushing them to the end we also dont want to
      ## reset the run defer because splicing means we're
      ## already in a run loop and dont want to create another!
      ## we also reset the .next property to properly reference
      ## our new obj

      ## we had a bug that would bomb on custom commands when it was the
      ## first command. this was due to nestedIndex being undefined at that
      ## time. so we have to ensure to check that its any kind of number (even 0)
      ## in order to know to splice into the existing array.
      nestedIndex = @prop("nestedIndex")

      ## if this is a number then we know
      ## we're about to splice this into our commands
      ## and need to reset next + increment the index
      if _.isNumber(nestedIndex)
        @commands.at(nestedIndex).set("next", obj)
        @prop("nestedIndex", nestedIndex += 1)

      ## we look at whether or not nestedIndex is a number, because if it
      ## is then we need to splice inside of our commands, else just push
      ## it onto the end of the queu
      index = if _.isNumber(nestedIndex) then nestedIndex else @commands.length

      @commands.splice(index, 0, obj)

      ## if nestedIndex is either undefined or 0
      ## then we know we're processing regular commands
      ## and not splicing in the middle of our commands
      if not nestedIndex
        @prop "runId", @defer(@run)

      return @

    _contains: ($el) ->
      doc = @private("document")

      contains = (el) ->
        $.contains(doc, el)

      ## either see if the raw element itself
      ## is contained in the document
      if _.isElement($el)
        contains($el)
      else
        return false if $el.length is 0

        ## or all the elements in the collection
        _.all $el.toArray(), contains

    _checkForNewChain: (chainerId) ->
      ## dont do anything if this isnt even defined
      return if _.isUndefined(chainerId)

      ## if we dont have a current chainerId
      ## then set one
      if not id = @prop("chainerId")
        @prop("chainerId", chainerId)
      else
        ## else if we have one currently and
        ## it doesnt match then nuke our subject
        ## since we've started a new chain
        ## and reset our chainerId
        if id isnt chainerId
          @prop("chainerId", chainerId)
          @nullSubject()

    ## the command method is useful for synchronously
    ## executing another command and wrapping it in a
    ## cancellable promise
    execute: (name, args...) ->
      Promise
        .resolve(@sync[name].apply(@, args))
        .cancellable()

    defer: (fn) ->
      @clearTimeout(@prop("timerId"))
      # @prop "timerId", _.defer _.bind(fn, @)
      @prop "timerId", setImmediate _.bind(fn, @)

    hook: (name) ->
      @private("hookName", name)

    ## returns the current chain so you can continue
    ## chaining off of cy without breaking the current
    ## subject
    chain: ->
      @prop("chain")

    _setRemoteIframeProps: ($iframe) ->
      @private "$remoteIframe", $iframe
      @private "window", $iframe.prop("contentWindow")
      @private "document", $iframe.prop("contentDocument")

      return @

    _setRunnable: (runnable, hookName) ->
      runnable.startedAt = new Date

      if _.isFinite(timeout = @Cypress.config("commandTimeout"))
        runnable.timeout timeout

      @hook(hookName)

      ## we store runnable as a property because
      ## we can't allow it to be reset with props
      ## since it is long lived (page events continue)
      ## after the tests have finished
      @private "runnable", runnable

      return @

    $$: (selector, context) ->
      context ?= @private("document")
      new $.fn.init selector, context

    _.extend $Cy.prototype, Backbone.Events

    ["_", "$", "Promise", "Blob", "moment"].forEach (lib) ->
      Object.defineProperty $Cy.prototype, lib, {
        get: ->
          $Cypress.Utils.warning("cy.#{lib} is now deprecated.\n\nThis object is now attached to 'Cypress' and not 'cy'.\n\nPlease update and use: Cypress.#{lib}")
          Cypress = @Cypress ? $Cypress.prototype

          if lib is "$"
            ## rebind the context of $
            ## to Cypress else it will be called
            ## with our cy instance
            _.bind(Cypress[lib], Cypress)
          else
            Cypress[lib]
      }

    @extend = (obj) ->
      _.extend @prototype, obj

    @set = (Cypress, runnable, hookName) ->
      return if not cy = Cypress.cy

      cy._setRunnable(runnable, hookName)

    @create = (Cypress, specWindow) ->
      ## clear out existing listeners
      ## if we already exist!
      if existing = Cypress.cy
        existing.stopListening()

      Cypress.cy = window.cy = new $Cy Cypress, specWindow

  return $Cy