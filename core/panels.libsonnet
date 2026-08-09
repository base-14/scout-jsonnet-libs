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

  pluginVersion:: '12.4.3',
  schemaVersion:: 42,

  datasource(uid):: { type: manifest.datasourceType, uid: uid },

  // Null handling, both thresholded at 1h:
  //   spanNulls   connect gaps SHORTER than 1h — a transient scrape miss
  //   insertNulls break the line on gaps LONGER than 1h — a real outage, which
  //               should read as a break rather than an interpolated straight line
  nullThresholdMs:: 3600000,

  target(datasourceUid, database, table, query, refId='A', format='time_series'):: {
    refId: refId,
    datasource: p.datasource(datasourceUid),
    database: database,
    table: table,
    query: query,
    format: format,
    dateTimeColDataType: 'TimeUnix',
    dateTimeType: 'DATETIME64',
    editorMode: 'sql',
    extrapolate: true,
    interval: '1m',
    intervalFactor: 1,
    round: '0s',
    skip_comments: true,
    add_metadata: true,
    useWindowFuncForMacros: true,
  },

  timeseries(id, title, gridPos, targets, unit=null):: {
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
          fillOpacity: 0,
          gradientMode: 'none',
          hideFrom: { legend: false, tooltip: false, viz: false },
          insertNulls: p.nullThresholdMs,
          lineInterpolation: 'linear',
          lineWidth: 1,
          pointSize: 5,
          scaleDistribution: { type: 'linear' },
          showPoints: 'auto',
          spanNulls: p.nullThresholdMs,
          stacking: { group: 'A', mode: 'none' },
          thresholdsStyle: { mode: 'off' },
        },
        mappings: [],
        thresholds: { mode: 'absolute', steps: [{ color: 'green', value: 0 }] },
      } + (if unit != null then { unit: unit } else {}),
      overrides: [],
    },
    options: {
      legend: { calcs: [], displayMode: 'list', placement: 'bottom', showLegend: true },
      tooltip: { mode: 'single', sort: 'none' },
    },
  },

  stat(id, title, gridPos, targets, unit=null):: {
    type: 'stat',
    id: id,
    title: title,
    gridPos: gridPos,
    datasource: targets[0].datasource,
    targets: targets,
    pluginVersion: p.pluginVersion,
    fieldConfig: {
      defaults: {
        color: { mode: 'thresholds' },
        mappings: [],
        thresholds: { mode: 'absolute', steps: [{ color: 'green', value: 0 }] },
      } + (if unit != null then { unit: unit } else {}),
      overrides: [],
    },
    options: {
      colorMode: 'value',
      graphMode: 'area',
      justifyMode: 'auto',
      orientation: 'auto',
      reduceOptions: { calcs: ['lastNotNull'], fields: '', values: false },
      textMode: 'auto',
    },
  },

  // A collapsible row header.
  //
  // Grafana stores a row's members in one of two places depending on its state:
  // a COLLAPSED row nests them inside its own `panels`, an EXPANDED row leaves
  // them as siblings that follow it in the dashboard's panel list. Get that
  // backwards and the panels vanish from the UI without any error. The caller
  // decides which, and passes `panels` accordingly — see `layout` in the
  // audience-export template.
  row(id, title, y, collapsed=false, panels=[]):: {
    type: 'row',
    id: id,
    title: title,
    collapsed: collapsed,
    gridPos: { h: 1, w: 24, x: 0, y: y },
    panels: panels,
  },

  dashboard(title, panels, variables=[], tags=[], time='now-6h'):: {
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
    graphTooltip: 1,  // shared crosshair
    links: [],
    preload: false,
    schemaVersion: p.schemaVersion,
    time: { from: time, to: 'now' },
    timepicker: { refresh_intervals: ['1m', '5m', '15m', '30m', '1h', '2h', '1d'] },
    timezone: 'browser',
    weekStart: '',
  },
}
