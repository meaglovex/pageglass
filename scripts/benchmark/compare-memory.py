#!/usr/bin/env python3
"""Validate and export only synthetic benchmark measurements, never browser profiles or logs."""
import argparse,json,statistics
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--baseline',type=Path,required=True)
parser.add_argument('--candidate',type=Path,required=True)
parser.add_argument('--chrome',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
runs=[];sources={};rows=[];reference_fixture=None;hardware=None
for label,directory in [('Pageglass 0.6',args.baseline),('Pageglass 0.7',args.candidate),('Chrome',args.chrome)]:
    summary=json.loads((directory/'summary.json').read_text())
    assert summary['status']=='completed','incomplete benchmark'
    source=summary['source'];fixture=source['memoryFixture']
    assert fixture['version']==3 and fixture['viewport']=={'width':1280,'height':760}
    if reference_fixture is None:reference_fixture=fixture;hardware=source['hardwareModel']
    assert fixture==reference_fixture and source['hardwareModel']==hardware,'different workload or hardware'
    engine='chrome' if label=='Chrome' else 'pageglass'
    sources[label]=source['browsers'][engine]
    if label!='Chrome':assert sources[label]['version'].startswith(label.split()[-1]+'.'),'browser version does not match report label'
    for tabs in [1,5,10]:
        selected=[r for r in summary['runs'] if r['engine']==engine and r['tabs']==tabs]
        assert len(selected)>=3,'at least three runs required'
        values=[]
        for run in selected:
            raw=json.loads((directory/run['run']/'result.json').read_text())
            assert raw['status']=='completed' and len(raw['tabs'])==tabs and len(raw['memorySamples'])==5
            assert all(t['ready'] and t.get('seenVisible') and t['rows']==1000 and t['viewport']==fixture['viewport'] for t in raw['tabs'].values())
            assert all(e['thermalState']=='nominal' and not e['screenLocked'] and not e['lowPowerMode'] for e in raw['environment'])
            samples=raw['memorySamples'];value=statistics.median(s['physicalFootprintBytes'] for s in samples)
            assert value>0 and value==run['physicalFootprintBytes']
            values.append(value)
            # Whitelist: local test measurements only, no profiles, cookies, arbitrary files or console logs.
            runs.append({'browser':label,'run':run['run'],'tabs':tabs,'fixtureReports':raw['tabs'],'environment':raw['environment'],'memorySamples':samples,'discardedSamples':raw.get('discardedSamples',[]),'elapsedSeconds':raw['elapsedSeconds']})
        rows.append({'browser':label,'tabs':tabs,'medianBytes':statistics.median(values),'minBytes':min(values),'maxBytes':max(values),'runMediansBytes':values})
regressions=[]
for tabs in [1,5,10]:
    baseline=next(r for r in rows if r['browser']=='Pageglass 0.6' and r['tabs']==tabs)
    candidate=next(r for r in rows if r['browser']=='Pageglass 0.7' and r['tabs']==tabs)
    change=candidate['medianBytes']/baseline['medianBytes']-1
    candidate['changeFromBaselinePercent']=change*100
    if change>0.10:regressions.append(tabs)
report={'scope':'Controlled same-origin PM fixture memory only; five full attributed footprint samples per run, three or more runs per tab count. Not a general browser performance claim.','hardwareModel':hardware,'fixture':reference_fixture,'browsers':sources,'summary':rows,'regressionInvestigationRequiredForTabs':regressions,'runs':runs}
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2))
print('| Browser | Tabs | Median MiB | Range MiB |')
print('|---|---:|---:|---:|')
for row in rows:
    print(f"| {row['browser']} | {row['tabs']} | {row['medianBytes']/1048576:.1f} | {row['minBytes']/1048576:.1f}–{row['maxBytes']/1048576:.1f} |")
print('Regression investigation required:',regressions)
