// Panel and dashboard scaffolding.
//
// Hand-rolled rather than grafonnet, matching what Scout emits on save. That
// match matters more than it looks: Scout normalises dashboards when they are
// saved, so if what we render differs from what it stores, `make verify` never
// sees an empty diff, every diff shows permanent phantom changes, and within a
// fortnight nobody reads diffs. Spike item 2 measures the normalisation set and
// corrects the defaults here.
local manifest = import 'manifest.libsonnet';

{
  local p = self,

  // Defaults for the Scout release this library was cut against. A consumer
  // pins its own with withCompat rather than editing them here.
  pluginVersion:: '12.4.3',
  schemaVersion:: 42,

  // Bind this module to a Scout version's constants.
  withCompat(c):: self {
    pluginVersion:: c.pluginVersion,
    schemaVersion:: c.schemaVersion,
  },

  datasource(uid):: { type: manifest.datasourceType, uid: uid },

  // A panel's info tooltip. Optional and omitted when unset, so a panel that
  // never had one renders byte-identically to before this existed.
  //
  // Worth carrying across on a port: these often hold the caveat that stops a
  // number being misread — "derived from HTTP status, not real uptime" on an
  // availability stat, say. Dropping them loses no data and no diff, which is
  // exactly why it goes unnoticed.
  described(description):: if description != null then { description: description } else {},

  // Null handling, both thresholded at 1h:
  //   spanNulls   connect gaps SHORTER than 1h — a transient scrape miss
  //   insertNulls break the line on gaps LONGER than 1h — a real outage, which
  //               should read as a break rather than an interpolated straight line
  nullThresholdMs:: 3600000,

  // `timeColumn`/`timeType` are what $timeFilter and $timeSeries bind to. The
  // OTel metric tables carry TimeUnix as DateTime64; the APM span rollup carries
  // Timestamp as DateTime. Leaving the default in place on the rollup binds a
  // column that does not exist there — which the plugin reports as a query
  // error, not as an empty panel, but only once someone opens it.
  //
  // `extrapolate` scales the trailing partial bucket up to a full interval. On a
  // rate that is what you want; on a pre-aggregated count it invents traffic
  // that was never recorded, so the APM panels turn it off.
  target(datasourceUid,
         database,
         table,
         query,
         refId='A',
         format='time_series',
         timeColumn='TimeUnix',
         timeType='DATETIME64',
         extrapolate=true):: {
    refId: refId,
    datasource: p.datasource(datasourceUid),
    database: database,
    table: table,
    query: query,
    format: format,
    dateTimeColDataType: timeColumn,
    dateTimeType: timeType,
    editorMode: 'sql',
    extrapolate: extrapolate,
    interval: '1m',
    intervalFactor: 1,
    round: '0s',
    skip_comments: true,
    add_metadata: true,
    useWindowFuncForMacros: true,
  },

  // Grafana's threshold ladder. The base step carries `value: null`, meaning
  // "everything below the next step" — a base of 0 leaves negatives uncoloured.
  thresholds(steps):: {
    mode: 'absolute',
    steps: [{ color: steps[0].color, value: null }]
           + [{ color: s.color, value: s.value } for s in steps[1:]],
  },

  defaultThresholds:: { mode: 'absolute', steps: [{ color: 'green', value: 0 }] },

  // A per-field override, matched by the column's display name. Table columns
  // are named by their SQL alias, so the matcher string and the alias must agree
  // — a typo in either silently drops the formatting rather than erroring.
  override(displayName, properties):: {
    matcher: { id: 'byName', options: displayName },
    properties: properties,
  },

  unit(value):: { id: 'unit', value: value },
  width(px):: { id: 'custom.width', value: px },
  thresholdProperty(steps):: { id: 'thresholds', value: p.thresholds(steps) },
  cellOptions(value):: { id: 'custom.cellOptions', value: value },
  links(value):: { id: 'links', value: value },
  gradientCell:: { type: 'color-background', mode: 'gradient' },

  timeseries(id,
             title,
             gridPos,
             targets,
             unit=null,
             fillOpacity=0,
             showPoints='auto',
             tooltipMode='single',
             tooltipSort='none',
             description=null):: {
    type: 'timeseries',
    id: id,
    title: title,
    gridPos: gridPos,
    datasource: targets[0].datasource,
    targets: targets,
    pluginVersion: p.pluginVersion,
    fieldConfig: {
      defaults: {
        color: { mode: 'palette-classic' },
        custom: {
          axisBorderShow: false,
          axisCenteredZero: false,
          axisColorMode: 'text',
          axisLabel: '',
          axisPlacement: 'auto',
          barAlignment: 0,
          drawStyle: 'line',
          fillOpacity: fillOpacity,
          gradientMode: 'none',
          hideFrom: { legend: false, tooltip: false, viz: false },
          insertNulls: p.nullThresholdMs,
          lineInterpolation: 'linear',
          lineWidth: 1,
          pointSize: 5,
          scaleDistribution: { type: 'linear' },
          showPoints: showPoints,
          spanNulls: p.nullThresholdMs,
          stacking: { group: 'A', mode: 'none' },
          thresholdsStyle: { mode: 'off' },
        },
        mappings: [],
        thresholds: p.defaultThresholds,
      } + (if unit != null then { unit: unit } else {}),
      overrides: [],
    },
    options: {
      legend: { calcs: [], displayMode: 'list', placement: 'bottom', showLegend: true },
      tooltip: { mode: tooltipMode, sort: tooltipSort },
    },
  } + p.described(description),

  stat(id,
       title,
       gridPos,
       targets,
       unit=null,
       thresholds=null,
       colorScheme='thresholds',
       textMode='auto',
       graphMode='area',
       decimals=null,
       description=null):: {
    type: 'stat',
    id: id,
    title: title,
    gridPos: gridPos,
    datasource: targets[0].datasource,
    targets: targets,
    pluginVersion: p.pluginVersion,
    fieldConfig: {
      defaults: {
                  color: { mode: colorScheme },
                  mappings: [],
                  thresholds: if thresholds != null then p.thresholds(thresholds) else p.defaultThresholds,
                } + (if unit != null then { unit: unit } else {})
                + (if decimals != null then { decimals: decimals } else {}),
      overrides: [],
    },
    options: {
      colorMode: 'value',
      graphMode: graphMode,
      justifyMode: 'auto',
      orientation: 'auto',
      reduceOptions: { calcs: ['lastNotNull'], fields: '', values: false },
      textMode: textMode,
    },
  } + p.described(description),

  // A tabular panel. Its target must be `format='table'` — the default
  // 'time_series' format makes the plugin look for a time column and return a
  // single mangled row.
  //
  // `sortBy` names a column by its display name, i.e. the SQL alias. Grafana
  // sorts client-side over whatever the query returned, so it re-orders the page
  // rather than the result set: it does not replace ORDER BY + LIMIT in the SQL.
  table(id, title, gridPos, targets, overrides=[], sortBy=null, cellHeight='sm', description=null):: {
    type: 'table',
    id: id,
    title: title,
    gridPos: gridPos,
    datasource: targets[0].datasource,
    targets: targets,
    pluginVersion: p.pluginVersion,
    fieldConfig: {
      defaults: {
        color: { mode: 'thresholds' },
        custom: { align: 'auto', cellOptions: { type: 'auto' }, inspect: false },
        mappings: [],
        thresholds: p.defaultThresholds,
      },
      overrides: overrides,
    },
    options: {
      cellHeight: cellHeight,
      footer: { countRows: false, fields: '', reducer: ['sum'], show: false },
      showHeader: true,
    } + (if sortBy != null then { sortBy: [{ displayName: sortBy, desc: true }] } else { sortBy: [] }),
  } + p.described(description),

  // ---- presentation overlays ------------------------------------------------
  //
  // Merged onto a panel: `p.timeseries(...) + p.bars()`. Overlays rather than
  // parameters so timeseries() keeps one canonical default and a panel states
  // only its differences.

  // Per-period statistics read as discrete bars; stacked, the bar height is
  // the total and the split is visible within it.
  bars(stacked=true):: {
    fieldConfig+: { defaults+: { custom+: {
      drawStyle: 'bars',
      fillOpacity: 60,
      gradientMode: 'hue',
      lineInterpolation: 'smooth',
      showPoints: 'never',
      axisSoftMin: 0,
    } + (if stacked then { stacking: { group: 'A', mode: 'normal' } } else {}) } },
  },

  // Count lines step rather than interpolate: the value is a per-period
  // total, and a slope between buckets would draw measurements that never
  // happened.
  steps:: {
    fieldConfig+: { defaults+: { custom+: {
      lineInterpolation: 'stepAfter',
      showPoints: 'never',
    } } },
  },

  legend(displayMode='list', calcs=['lastNotNull']):: {
    options+: { legend+: { displayMode: displayMode, calcs: calcs } },
  },

  // A collapsible row header.
  //
  // Scout stores a row's members in one of two places depending on its state:
  // a COLLAPSED row nests them inside its own `panels`, an EXPANDED row leaves
  // them as siblings that follow it in the dashboard's panel list. Get that
  // backwards and the panels vanish from the UI without any error. The caller
  // decides which, and passes `panels` accordingly — see `layout` in the
  // audience-export template.
  row(id, title, y, collapsed=false, panels=[], description=null):: {
    type: 'row',
    id: id,
    title: title,
    collapsed: collapsed,
    gridPos: { h: 1, w: 24, x: 0, y: y },
    panels: panels,
  } + p.described(description),

  dashboard(title,
            panels,
            variables=[],
            tags=[],
            time='now-6h',
            refresh=null,
            description=null,
            graphTooltip=1):: {
                                title: title,
                                tags: tags,
                                panels: panels,
                                templating: { list: variables },
                                annotations: {
                                  list: [{
                                    builtIn: 1,
                                    datasource: manifest.builtinAnnotationDatasource,
                                    enable: true,
                                    hide: true,
                                    iconColor: 'rgba(0, 211, 255, 1)',
                                    name: 'Annotations & Alerts',
                                    type: 'dashboard',
                                  }],
                                },
                                editable: true,
                                fiscalYearStartMonth: 0,
                                graphTooltip: graphTooltip,  // 1 = shared crosshair
                                links: [],
                                preload: false,
                                schemaVersion: p.schemaVersion,
                                time: { from: time, to: 'now' },
                                timepicker: { refresh_intervals: ['1m', '5m', '15m', '30m', '1h', '2h', '1d'] },
                                timezone: 'browser',
                                weekStart: '',
                              } + (if refresh != null then { refresh: refresh } else {})
                              + (if description != null then { description: description } else {}),
}
