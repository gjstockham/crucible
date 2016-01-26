$(window).on('load', ->
  new Crucible.TestExecutor()
)

class Crucible.TestExecutor
  suites: []
  suitesById: {}
  testsById: {}
  templates:
    suiteSelect: 'views/templates/servers/suite_select'
    suiteResult: 'views/templates/servers/suite_result'
    testResult: 'views/templates/servers/partials/test_result'
    testRequests: 'views/templates/servers/partials/test_requests'
    testRequestDetails: 'views/templates/servers/partials/test_request_details'
    testRunSummary: 'views/templates/servers/partials/test_run_summary'
  html:
    selectAllButton: '<i class="fa fa-close"></i>'
    deselectAllButton: '<i class="fa fa-check"></i>'
    collapseAllButton: '<i class="fa fa-compress"></i>'
    expandAllButton: '<i class="fa fa-expand"></i>'
    spinner: '<span class="fa fa-lg fa-fw fa-spinner fa-pulse tests"></span>'
    unavailableError: '<div class="alert alert-danger"><strong>Error: </strong> Server Unavailable</div>'
    genericError: '<div class="alert alert-danger"><strong>Error: </strong> Tests could not be executed</div>'
    unauthorizedError: '<div class="alert alert-danger"><strong>Error: Server unauthorized or authorization expired</strong></div>'
  filters:
    search: ""
    executed: false
    starburstNode: null
    supported: true
    failures: false
  statusWeights: {'pass': 1, 'skip': 2, 'fail': 3, 'error': 4}
  checkStatusTimeout: 4000
  selectedTestRunId: null
  defaultSelection: null

  constructor: ->
    @element = $('.test-executor')
    return unless @element.length
    @element.data('testExecutor', this)
    @serverId = @element.data('server-id')
    @runningTestRunId = @element.data('current-test-run-id')
    @progress = $("##{@element.data('progress')}")
    @registerHandlers()
    @defaultSelection = @parseDefaultSelection(window.location.hash)
    @loadTests()
    @element.find('.filter-by-executed').css('display', 'none')
    @element.find('.filter-by-failures').css('display', 'none')

  registerHandlers: =>
    @element.find('.execute').click(@startTestRun)
    $('#cancel-modal #cancel-confirm').click(@cancelTestRun)
    @element.find('.selectDeselectAll').click(@selectDeselectAll)
    @element.find('.expandCollapseAll').click(@expandCollapseAll)
    @element.find('.clear-past-run-data').click(@clearPastTestRunData)
    @element.find('.filter-by-executed a').click(@filterByExecutedHandler)
    @element.find('.filter-by-failures a').click(@filterByFailuresHandler)
    @element.find('.filter-by-supported a').click(@filterBySupportedHandler)
    # turn off toggling for tags
    @element.find('.change-test-run').click(@togglePastRunsSelector)
    @element.find('.close-change-test-run').click(@togglePastRunsSelector)
    @element.find('.past-test-runs-selector').change(@updateCurrentTestRun)
    @element.find('.add-filter-link').click(@toggleFilterSelector)
    @element.find('.filter-selector').change(@addFilter)
    @element.find('.add-filter-selector a').click(@toggleFilterSelector)
    @searchBox = @element.find('.test-results-filter')
    @searchBox.on('keyup', @searchBoxHandler)
    @element.find('.starburst').on('starburstInitialized', (event) =>
      @starburst = @element.find('.starburst').data('starburst')
      @starburst.addListener(this)
      if @filters.starburstNode
        @starburst.transitionTo(@filters.starburstNode.name, 0)
      false
    )
    $('#conformance-data').on('conformanceInitialized', (event) =>
      @loadTests()
      false
    )
    $('#conformance-data').on('conformanceError', (event) =>
      @filterBySupportedHandler()
      false
    )
    @bindToolTips()

  bindToolTips: =>
    @element.find('.selectDeselectAll').tooltip()
    @element.find('.expandCollapseAll').tooltip()
    @element.find('.clear-past-run-data').tooltip()
    @element.find('.change-test-run').tooltip()
    @element.find('.close-change-test-run').tooltip()

  loadTests: =>
    $.getJSON("/servers/#{@serverId}/supported_tests.json").success((data) =>
      @suites = data['tests']
      @renderSuites() if !@defaultSelection
      @continueTestRun() if @runningTestRunId && !@defaultSelection
      @filter(supported: true)
      @renderPastTestRunsSelector({text: 'Select past test run', value: '', disabled: true})
    ).complete(() -> $('.test-result-loading').hide())

  renderSuites: =>
    @element.find('.test-results .button-holder').removeClass('hide')
    suitesElement = @element.find('.test-suites')
    suitesElement.empty()
    $(@suites).each (i, suite) =>
      @suitesById[suite.id] = suite
      $(suite.methods).each (j, test) =>
        @testsById[test.id] = test
      suitesElement.append(HandlebarsTemplates[@templates.suiteSelect]({suite: suite}))
      suiteElement = suitesElement.find("#test-#{suite.id}")
      suiteElement.data('suite', suite)
      $(suite.methods).each (i, test) =>
        @addClickTestHandler(test, suiteElement)

  renderPastTestRunsSelector: (elementToAdd) =>
    $.getJSON("/servers/#{@serverId}/past_runs").success((data) =>
      return unless data
      validDefaultSelection = false
      selector = @element.find('.past-test-runs-selector')
      selector.empty()
      if elementToAdd
        selector.append("<option value='#{elementToAdd.value}' disabled='#{elementToAdd.disabled}'>#{elementToAdd.text}</option>")
      selector.show()
      $(data['past_runs']).each (i, test_run) =>
        validDefaultSelection = true if @defaultSelection && @defaultSelection.testRunId == test_run.id
        selection = "<option value='#{test_run.id}'> #{moment(test_run.date).format('MM/DD/YYYY')} </option>"
        selector.append(selection)

      if validDefaultSelection
        @togglePastRunsSelector() # Mimic showing the date dropdown, will be toggled off later
        selector.val(@defaultSelection.testRunId)
        @updateCurrentTestRun()
      else
        @defaultSelection = null #couldn't find the test run, so hash in url is invalid
    )

  clearPastTestRunData: =>
    @hideTestResultSummary()
    @element.find('.selected-run').empty()
    @element.find('.clear-past-run-data').hide()
    @renderSuites()
    @filter(executed: false)

  updateCurrentTestRun: =>
    @element.find('.test-suites').empty()
    @element.find('.execute').hide()
    @element.find('.suite-selectors').hide()
    @hideTestResultSummary()
    $('.test-result-loading').show()
    selector = @element.find('.past-test-runs-selector')
    @selectedTestRunId = selector.val()
    suiteIds = $($.map(selector.find('option'), (e) -> e.value))
    $.getJSON("/servers/#{@serverId}/test_runs/#{@selectedTestRunId}").success((data) =>
      return unless data
      @showTestRunSummary(data.test_run)
      @renderSuites()
      $(data['test_run'].test_results).each (i, result) =>
        suiteId = result.test_id
        suiteElement = @element.find("#test-#{suiteId}")
        @handleSuiteResult(@suitesById[suiteId], {tests: result.result}, suiteElement)
      if @defaultSelection
        @element.find("#test-#{@defaultSelection.suiteId} a.collapsed").click()
        @element.find("#test-#{@defaultSelection.suiteId} ##{@defaultSelection.testId}").click()
        @defaultSelection = null #prevent from auto-navigation from default selection any more
      @filter(supported: data.test_run.supported_only)
      @filter(executed: true, supported: (if data.test_run.supported_only then true else false))
      date = new Date(data.test_run.date)
      m = date.getMonth() + 1
      d = date.getDate()
      y = date.getFullYear()
      @setTestRunDateDisplay(m, d, y)
      @element.find('.clear-past-run-data').show()
      @element.find('.change-test-run').hide()
      @togglePastRunsSelector()
    ).complete(() -> 
      $('.execute').show()
      $('.suite-selectors').show()
      $('.test-result-loading').hide()
      selector.children().attr('selected', false)
      selector.children().first().attr('selected', true)
    )

  setTestRunDateDisplay: (month, day, year) =>
    @element.find('.selected-run').html(month + '/' + day + '/' + year)

  togglePastRunsSelector: =>
    @element.find('.display-data-changer').toggle()
    @element.find('.display-data').toggle()
    @element.find('.close-change-test-run').toggle()
    @element.find('.change-test-run').toggle()

  toggleFilterSelector: =>
    @element.find('.add-filter-link').toggle()
    @element.find('.add-filter-selector').toggle()

  selectDeselectAll: =>
    suiteElements = @element.find('.test-run-result :visible :checkbox')
    button = $('.selectDeselectAll')
    if !$(suiteElements).prop('checked')
      $(suiteElements).prop('checked', true)
      $(button).html(@html.selectAllButton)
    else
      $(suiteElements).prop('checked', false)
      $(button).html(@html.deselectAllButton)

  expandCollapseAll: =>
    suiteElements = @element.find('.test-run-result .collapse')
    button = $('.expandCollapseAll')
    if !$(suiteElements).hasClass('in')
      $(suiteElements).collapse('show')
      $(button).html(@html.collapseAllButton)
    else
      $(suiteElements).collapse('hide')
      $(button).html(@html.expandAllButton)

  prepareTestRun: (suiteIds) =>
    @processedResults = {}
    @element.find('.execute').hide()
    @element.find('.suite-selectors').hide()
    @element.find('.cancel').show()
    @resetSuitePanels()
    @progress.parent().collapse('show')
    @element.find('.past-test-runs-selector').attr("disabled", true)
    @renderPastTestRunsSelector({text: 'Test in progress...', value: '', disabled: true})
    @hideTestResultSummary()
    @progress.find('.progress-bar').css('width',"2%")
    @element.queue("executionQueue", @checkTestRunStatus)
    @element.queue("executionQueue", @finishTestRun)

    suiteIds.each (i, suiteId) =>
      suiteElement = @element.find("#test-#{suiteId}")
      suiteElement.find("input[type=checkbox]").attr("checked", true)
      suiteElement.find('.test-status').empty().append(@html.spinner)
      suiteElement.addClass("executed")

    @element.find('.test-run-result').hide()
    @filter(executed: true)

  continueTestRun: =>
    $.get("/servers/#{@serverId}/test_runs/#{@runningTestRunId}").success((result) =>
      @filter(supported: result.test_run.supported_only)
      #@element.find('.filter-by-supported').collapse(if result.test_run.supported_only then 'show' else 'hide')
      @prepareTestRun($(result.test_run.test_ids))
      @element.dequeue("executionQueue")
    )

  startTestRun: =>
    suiteIds = $($.map(@element.find(':checked'), (e) -> e.name))
    @element.find(".test-result-error").empty()
    if suiteIds.length > 0
      @prepareTestRun(suiteIds)
      suiteIds = $.map(@element.find(':checked'), (e) -> e.name)
      $.post("/servers/#{@serverId}/test_runs.json", { test_ids: suiteIds, supported_only: @filters.supported }).success((result) =>
        @runningTestRunId = result.test_run.id
        @element.dequeue("executionQueue")
      )
    else 
      @flashWarning('Please select at least one test suite')

  cancelTestRun: =>
    if @runningTestRunId?
      $.post("/servers/#{@serverId}/test_runs/#{@runningTestRunId}/cancel").success( (result) =>
        location.reload()
      )
    else 
      $("#cancel-modal").hide()

  searchBoxHandler: =>
    @filter(search: @searchBox.val().toLowerCase().replace(/\s/g, ""))

  filterByExecutedHandler: =>
    @filter(executed: false)
    false

  filterByFailuresHandler: =>
    @filter(failures: false)
    false

  filterBySupportedHandler: =>
    @filter(supported: false)
    false

  addFilter: =>
    selector = @element.find('.filter-selector')
    filter = selector.val()
    @filters["#{filter}"] = true
    @filter(@filters)
    @toggleFilterSelector()
    selector.children().attr('selected', false)
    selector.children().first().attr('selected', true)

  filter: (filters)=>
    if filters?
      for f of filters
        @filters[f] = filters[f]
    # filter suites
    suiteElements = @element.find('.test-run-result')
    suiteElements.show()

    @element.find('.filter-by-executed').css('display', (if @filters.executed then 'inline-block' else 'none'))
    @element.find('.filter-by-supported').css('display', (if @filters.supported then 'inline-block' else 'none'))
    @element.find('.filter-by-failures').css('display', (if @filters.failures then 'inline-block' else 'none'))

    starburstTestIds = _.union(@filters.starburstNode.failedIds, @filters.starburstNode.skippedIds, @filters.starburstNode.errorsIds, @filters.starburstNode.passedIds) if @filters.starburstNode?
    $(suiteElements).each (i, suiteElement) =>
      suiteElement = $(suiteElement)
      suite = suiteElement.data('suite')
      childrenIds = suite.methods.map (m) -> m.id
      suiteElement.hide() if @filters.search.length > 0 && (suite.name.toLowerCase()).indexOf(@filters.search) < 0
      suiteElement.hide() if @filters.executed && !suiteElement.hasClass("executed")
      suiteElement.hide() if @filters.starburstNode? && !(_.intersection(starburstTestIds, childrenIds).length > 0)
      suiteElement.hide() if @filters.supported && !(suite.supported)
      suiteElement.hide() if @filters.failures && suiteElement.find(".test-status .passed").length
    # filter tests in a suite
    testElements = @element.find('.suite-handle')
    testElements.show()
    $(testElements).each (i, testElement) =>
      testElement = $(testElement)
      test = @testsById[testElement.attr('id')]
      testElement.hide() if @filters.supported && !(test.supported)

  resetSuitePanels: =>
    suitesElement = @element.find('.test-suites')
    panels = @element.find('.test-run-result.executed')
    $(panels).each (i, panel) =>
      suite_id = (panel.id).substr(5)
      suite = @suitesById[suite_id]
      newPanel = HandlebarsTemplates[@templates.suiteSelect]({suite: suite})
      $(panel).replaceWith(newPanel)
      newElement = suitesElement.find("#test-#{suite.id}")
      newElement.data('suite', suite)
      $(suite.methods).each (i, test) =>
        @addClickTestHandler(test, newElement)

  checkTestRunStatus: =>
    return false unless @runningTestRunId?
    $.get("/servers/#{@serverId}/test_runs/#{@runningTestRunId}").success((result) =>
      test_run = result.test_run
      percent_complete = test_run.test_results.length / test_run.test_ids.length
      @progress.find('.progress-bar').css('width',"#{(Math.max(2, percent_complete * 100))}%")
      if Object.keys(@processedResults).length < test_run.test_results.length
        for result in test_run.test_results
          suiteId = result.test_id
          suite = @suitesById[suiteId]
          suiteElement = $("#test-#{suiteId}")
          @handleSuiteResult(suite, result, suiteElement) unless @processedResults[suiteId]
          @processedResults[suiteId] = true
        @filter()
      if test_run.status == "unavailable"
        @displayError(@html.unavailableError)
        @element.dequeue("executionQueue")
      else if test_run.status == "unauthorized"
        @displayError(@html.unauthorizedError)
        @element.dequeue("executionQueue")
      else if test_run.status == "error"
        @displayError(@html.genericError)
        @element.dequeue("executionQueue")
      else if test_run.status == "finished"
        @showTestRunSummary({test_results: test_run.test_results})
        @element.dequeue("executionQueue")
      else if test_run.status != "cancelled" and @runningTestRunId?
        setTimeout(@checkTestRunStatus, @checkStatusTimeout)
    )

  showTestRunSummary: (results) =>
    summaryPanel = @element.find('.testrun-summary')
    summaryData = {
      suites: {total: 0},
      tests: {total: 0}
    }

    for status, weight of @statusWeights
      summaryData.suites[status] = 0
      summaryData.tests[status] = 0

    $(results.test_results).each (i, suite) =>
      suiteStatus = 'pass'
      $(suite.result).each (j, test) =>
        suiteStatus = test.status if @statusWeights[suiteStatus] < @statusWeights[test.status]
        summaryData.tests[test.status]++
        summaryData.tests.total++
      summaryData.suites[suiteStatus]++
      summaryData.suites.total++

    summaryContent = HandlebarsTemplates[@templates.testRunSummary](summaryData)
    summaryPanel.replaceWith(summaryContent)
    summaryPanel.show()

  hideTestResultSummary: =>
    @element.find('.testrun-summary').hide()

  handleSuiteResult: (suite, result, suiteElement) =>
    suiteStatus = 'pass'
    if result.result
      result.tests = result.result
    $(result.tests).each (i, test) =>
      suiteStatus = test.status if @statusWeights[suiteStatus] < @statusWeights[test.status]
    result.suiteStatus = suiteStatus

    suiteElement.replaceWith(HandlebarsTemplates[@templates.suiteResult]({suite: suite, result: result}))
    suiteElement = @element.find("#test-"+suite.id)
    suiteElement.data('suite', suite)
    $(result.tests).each (i, test) =>
      test.test_result_id = result._id if !test.test_result_id && result._id # id may come from different spots depending on if just run
      if (i == 0)
        # add click handler for default selection
        @addClickRequestDetailsHandler(test, suiteElement)
        testRunId = @selectedTestRunId
        testRunId = @runningTestRunId if @runningTestRunId
        @addClickPermalinkHandler(testRunId, suiteElement, test.id)
      @addClickTestHandler(test, suiteElement)

  displayError: (message) =>
    @element.find(".test-result-error").html(message)
    @element.find('.test-status').empty()

  finishTestRun: =>
    new Crucible.Summary()
    new Crucible.TestRunReport()
    @progress.parent().collapse('hide')
    @progress.find('.progress-bar').css('width',"0%")
    @element.find('.execute').show()
    @element.find('.suite-selectors').show()
    @element.find('.cancel').hide()
    @element.find('.past-test-runs-selector').attr("disabled", false)
    @renderPastTestRunsSelector({text: 'Select past test run', value: '', disabled: true})
    run_date = @element.find('.past-test-runs-selector').children().last().html()
    @element.find('.selected-run').empty().html(run_date)
    @element.find('')
    @element.find('.clear-past-run-data').show()
    $("#cancel-modal").hide()
    @selectedTestRunId = @runningTestRunId
    @runningTestRunId = null

  addClickTestHandler: (test, suiteElement) => 
    handle = suiteElement.find(".suite-handle[data-key='#{test.key}']")
    handle.click =>
      suiteElement.find(".suite-handle").removeClass('active')
      handle.addClass('active')
      suiteElement.find('.test-results').empty().append(HandlebarsTemplates[@templates.testResult]({test: test}))
      testRunId = @selectedTestRunId
      testRunId = @runningTestRunId if @runningTestRunId
      @addClickRequestDetailsHandler(test, suiteElement)
      @addClickPermalinkHandler(testRunId, suiteElement, test.id)

  addClickRequestDetailsHandler: (test, suiteElement) =>
    suiteElement.find(".data-link").click (e) => 
      html = HandlebarsTemplates[@templates.testRequests]({test: test})
      detailsTemplate = @templates.testRequestDetails
      $('#data-modal .modal-body').empty().append(html)
      $('#data-modal .modal-body code').each (index, code) ->
        hljs.highlightBlock(code)
      refresh_link = $('#data-modal .request-panel-refresh')
      refresh_link.tooltip()
      refresh_link.click (e) -> 
        e.preventDefault
        test_result_id = test.test_result_id.$oid
        test_id = test.id
        request_index = $(@).data('index')
        refresh_icon = $(@).find('i')
        content_panel = $("#request_#{request_index}")
        loading_html='<div style="text-align:center"><i class="fa fa-lg fa-fw fa-spinner fa-pulse"></i> Loading</div>'
        refresh_icon.addClass('fa-spin')
        content_panel.empty().append(loading_html)
        content_panel.collapse('show')
        $.getJSON("/test_results/#{test_result_id}/reissue_request.json?test_id=#{test_id}&request_index=#{request_index}").success((data) =>
          refresh_icon.removeClass('fa-spin')
          detailsHtml = HandlebarsTemplates[detailsTemplate]({index: request_index, call: data})
          $("#request_#{request_index}_status").html(data.response.code)
          content_panel.empty().append(detailsHtml)
          content_panel.find(".request-resent-message").show()
        )

  addClickPermalinkHandler: (testRunId, suiteElement, testId) =>
    permalink = suiteElement.find(".test-permalink-link")
    return unless permalink.length
    suiteId = suiteElement.attr("id").substring(5) #strip off "test-" prefix
    hash="##{testRunId}/#{suiteId}/#{testId}"
    path="#{window.location.protocol}//#{window.location.host}#{window.location.pathname}#{hash}"
    permalink.attr("href",hash)
    permalink.click (e) => e.preventDefault()
    clipboard = new Clipboard(permalink[0], text: () => path)
    clipboard.on('success', () => suiteElement.find(".permalink-copied").fadeIn('slow'))
    clipboard.on('error', () => window.location.hash=hash) #fallback mainly for safari

  flashWarning: (message) =>
    warningBanner = @element.find('.warning-message')
    $(warningBanner).html(message)
    $(warningBanner).fadeIn()
    $(warningBanner).delay(1000).fadeOut(1500)

  filterTestsByStarburst: (node) ->
    if node == 'FHIR'
      @filter(starburstNode: null)
    else
      @filter(starburstNode: @starburst.nodeMap[node])

  parseDefaultSelection: (hash) =>
    return null if hash.split("/").length != 3
    [testRunId, suiteId, testId] = hash.substring(1).split("/")
    return {testRunId: testRunId, suiteId: suiteId, testId: testId}

  transitionTo: (node) ->
    _.defer(=>
      @filterTestsByStarburst(node))
