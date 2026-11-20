// KubeStellar Console Tier 2 dynamic card for the Mjolnir fleet.
// The token {{CONSOLE_ORIGIN}} is replaced by build-card.py.
function MjolnirFleetCard() {
  const url = '{{CONSOLE_ORIGIN}}/api/mcp/custom-resources?group=mjolnir.kubestellar.io&version=v1alpha1&resource=mjolnirnodes&limit=500'
  const { data, loading, error, refetch } = useCardFetch(url, { refreshInterval: 15000 })

  const items = (data && data.items) ? data.items : []
  const updates = items.filter(i => i.status && i.status.updateAvailable === true).length
  const locks = items.filter(i => i.status && i.status.rebootLock === true).length
  const offline = items.filter(i => {
    if (!i.status || !i.status.lastCheck) return true
    return (Date.now() - Date.parse(i.status.lastCheck)) > 300000
  }).length

  const badge = (value, good, bad) => (
    <span className={cn('text-2xs px-1.5 py-0.5 rounded', value ? bad : good)}>
      {value ? 'YES' : 'NO'}
    </span>
  )

  if (loading && items.length === 0) return <SpinWrapper><Spinner /></SpinWrapper>
  if (error) return (
    <div className="p-3 text-sm text-red-400">
      Fleet API error: {String(error)} <button onClick={refetch} className="ml-2 underline">retry</button>
    </div>
  )

  return (
    <div className="h-full flex flex-col gap-2 p-1 text-xs">
      <div className="grid grid-cols-4 gap-2">
        <div className="rounded border border-border p-2 text-center">
          <div className="text-lg font-semibold">{items.length}</div>
          <div className="text-2xs text-muted-foreground">Nodes</div>
        </div>
        <div className="rounded border border-border p-2 text-center">
          <div className="text-lg font-semibold text-amber-400">{updates}</div>
          <div className="text-2xs text-muted-foreground">Updates pending</div>
        </div>
        <div className="rounded border border-border p-2 text-center">
          <div className="text-lg font-semibold text-red-400">{locks}</div>
          <div className="text-2xs text-muted-foreground">Reboot locks</div>
        </div>
        <div className="rounded border border-border p-2 text-center">
          <div className="text-lg font-semibold text-red-400">{offline}</div>
          <div className="text-2xs text-muted-foreground">Stale check-in</div>
        </div>
      </div>

      <div className="overflow-auto">
        <table className="w-full text-left border-collapse">
          <thead>
            <tr className="text-2xs text-muted-foreground border-b border-border">
              <th className="p-1">Node</th>
              <th className="p-1">Role</th>
              <th className="p-1">Version</th>
              <th className="p-1">Update</th>
              <th className="p-1">Reboot</th>
              <th className="p-1">WiFi</th>
              <th className="p-1">Varlink</th>
              <th className="p-1">Last check</th>
            </tr>
          </thead>
          <tbody>
            {items.map((item, idx) => {
              const s = item.status || {}
              const w = s.wifi || {}
              return (
                <tr key={item.name || idx} className="border-b border-border/50">
                  <td className="p-1 font-mono">{item.name}</td>
                  <td className="p-1">{(item.spec && item.spec.role) || s.role || '-'}</td>
                  <td className="p-1 font-mono">{s.version || '-'}</td>
                  <td className="p-1">{badge(s.updateAvailable === true, 'text-green-400', 'bg-amber-900/40 text-amber-300')}</td>
                  <td className="p-1">{badge(s.rebootRequired === true, 'text-green-400', 'bg-red-900/40 text-red-300')}</td>
                  <td className="p-1">{w.ssid ? (w.ssid + ' / ' + (w.state || '-') + ' / ' + (w.signal || '-')) : 'none'}</td>
                  <td className="p-1 font-mono text-2xs">{(item.spec && item.spec.varlinkEndpoint) || '-'}</td>
                  <td className="p-1 text-2xs">{s.lastCheck || '-'}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      <button onClick={refetch} className="self-end text-2xs underline text-muted-foreground">refresh</button>
    </div>
  )
}
