from pathlib import Path
import argparse,csv,re,sys,math
B=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser(); ap.add_argument('--no-write',action='store_true'); a=ap.parse_args()
r=[]
def c(name,cond,detail=''):
    r.append((bool(cond),name,detail))
def t(f):
    p=B/f
    return p.read_text(errors='replace') if p.exists() else ''

def luminance(hexv):
    h=hexv.lstrip('#'); vals=[int(h[i:i+2],16)/255 for i in (0,2,4)]
    vals=[v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4 for v in vals]
    return .2126*vals[0]+.7152*vals[1]+.0722*vals[2]
def contrast(a,b):
    la,lb=luminance(a),luminance(b); hi,lo=max(la,lb),min(la,lb)
    return (hi+.05)/(lo+.05)

required=['00_README.md','MASTER.md','TOKENS.md','COMPONENTS.md','PATTERNS.md','TABLE_LAYOUT.md','RESPONSIVE.md','ACCESSIBILITY.md','AUTH_AND_LOGIN.md','SIDEBAR_NAVIGATION.md','PAGE_OVERRIDES_V1_8.md','DESIGN_REVIEW_CHECKLIST.md','page_component_matrix.csv','component_inventory.csv','CHANGELOG_V1_8.md']
for f in required:c('file '+f,(B/f).exists())

c('Version v1.8 current',t('00_README.md').startswith('# EIU Recruitment Design System v1.8'))
c('Sidebar title v1.8',t('SIDEBAR_NAVIGATION.md').splitlines() and 'v1.8' in t('SIDEBAR_NAVIGATION.md').splitlines()[0])
c('Table layout title v1.8',t('TABLE_LAYOUT.md').splitlines() and 'v1.8' in t('TABLE_LAYOUT.md').splitlines()[0])
c('Tokens title v1.8',t('TOKENS.md').splitlines() and 'v1.8' in t('TOKENS.md').splitlines()[0])
c('Page override v1.8 exists',(B/'PAGE_OVERRIDES_V1_8.md').exists())
c('Prototype sync target v1.8','prototype' in t('00_README.md').lower() and 'v1.8' in t('00_README.md').lower())

layout=t('TABLE_LAYOUT.md')
for label,decl in [('Application Inbox',1560),('Interview',1480),('Báo cáo phỏng vấn HR',1610)]:
    m=re.search(rf'### {re.escape(label)}\s+— min table width (\d+)px\n(.*?)(?=\n###|\n## 12)',layout,re.S)
    if not m:
        c(label+' block exists',False); continue
    stated=int(m.group(1)); widths=[int(x) for x in re.findall(r'\|[^\n|]+\|\s*(\d+)px\s*\|',m.group(2))]
    c(label+' width arithmetic',stated==decl and sum(widths)==stated,f'sum={sum(widths)} stated={stated} expected={decl}')

allcur='\n'.join(t(f) for f in ['MASTER.md','COMPONENTS.md','TOKENS.md','RESPONSIVE.md','PATTERNS.md','TABLE_LAYOUT.md'])
c('Drawer legacy 55vw contradiction absent','max 55vw' not in allcur and '760–860px, max 55vw' not in allcur)
c('Drawer formula current','min(820px, available-content-width)' in t('COMPONENTS.md') and 'min(820px, available-content-width)' in t('TOKENS.md'))
c('No generic overflow-wrap anywhere','must **not** use `overflow-wrap:anywhere`' in layout)
c('Sticky context columns','Select + primary identity' in layout)
c('Single table authority','single Design source' in layout)
c('Latest Submission parent summary','latest Submission' in layout and 'submitted_at DESC, submission_id DESC' in layout)

mat=t('page_component_matrix.csv')
line=next((x for x in mat.splitlines() if x.startswith('Quản lý phiếu ứng tuyển,')),'')
c('HR Inbox file components',all(x in line for x in ['FileList','FilePreview','AsyncStatus','ConfirmationDialog']))
for tok in ['TableScrollContainer','PrivacyNoticeAcknowledgement','SubmissionSelector','AuthBindingBadge','MasterUsageGuard']:
    c('Matrix '+tok,tok in mat)
report_line=next((x for x in mat.splitlines() if x.startswith('Báo cáo phỏng vấn HR,')),'')
c('HR Report scroll container','TableScrollContainer' in report_line)

c('Candidate EDIT Privacy explicit','EDIT_SUBMISSION' in t('PAGE_OVERRIDES_V1_8.md') and 'PrivacyNoticeAcknowledgement' in t('PAGE_OVERRIDES_V1_8.md') and 'Save disabled until acknowledged' in t('PAGE_OVERRIDES_V1_8.md'))
c('Internal User hard delete absent normal UI','does **not** expose Internal User hard-delete' in t('PAGE_OVERRIDES_V1_8.md'))
c('SubmissionSelector returns submission_id','submission_id' in t('PAGE_OVERRIDES_V1_8.md') or 'submission_id' in t('COMPONENTS.md'))
c('Email no attachments Phase1','no email attachments in phase 1' in t('COMPONENTS.md').lower() or 'no attachments' in t('PATTERNS.md').lower())
c('Email retry semantics','duplicate logical' in t('PATTERNS.md').lower() and 'at-least-once' in t('PATTERNS.md').lower())
for bad in ['retry must not create duplicate messages','prevents duplicate sends','retries do not duplicate sends']:
    c('No forbidden email phrase '+bad,bad not in '\n'.join(t(f).lower() for f in required if f.endswith('.md')))
c('PII search not URL','name/email/phone search terms remain local/request state and are not copied into url' in t('PATTERNS.md').lower())
goldline=' '.join(x for x in t('TOKENS.md').splitlines() if '--eiu-gold' in x or ('body text' in x.lower() and 'gold' in x.lower()))
c('Gold normal text restriction','body text' in goldline.lower() and 'not' in goldline.lower())

# Numeric contrast gate
pairs={
 'Success':('#3B6A2A','#EAF3E6'),
 'Warning':('#8A4F00','#FFF0DE'),
 'Danger':('#B44425','#F8E5E0'),
 'Info':('#144069','#E5EDF5'),
 'Neutral':('#68686B','#EEF0F1'),
 'Purple':('#4B479D','#ECEBFA'),
}
for name,(fg,bg) in pairs.items():
    ratio=contrast(fg,bg)
    c('Contrast '+name,ratio>=4.5,f'{ratio:.2f}:1')

c('200 percent zoom acceptance','200% text zoom' in t('ACCESSIBILITY.md') and 'no loss' in t('ACCESSIBILITY.md').lower())
c('400 percent reflow acceptance','400% reflow' in t('ACCESSIBILITY.md') and '1.4.10' in t('ACCESSIBILITY.md'))
c('Sticky focus acceptance','sticky' in t('DESIGN_REVIEW_CHECKLIST.md').lower() and 'focus' in t('DESIGN_REVIEW_CHECKLIST.md').lower())
c('Touch target 44','44' in t('ACCESSIBILITY.md') or '44' in t('RESPONSIVE.md'))
c('Operational type 16px','**16px**' in t('TOKENS.md'))

nums=re.findall(r'(?m)^##\s+(\d+)\.',t('COMPONENTS.md'))
dup=sorted({n for n in nums if nums.count(n)>1})
c('Component numbering unique',len(nums)==len(set(nums)),f'duplicates={dup}')
c('Components include Privacy','PrivacyNoticeAcknowledgement' in t('COMPONENTS.md'))
c('Components include Auth binding','AuthBindingBadge' in t('COMPONENTS.md'))
c('Components include Master usage','MasterUsageGuard' in t('COMPONENTS.md'))

# Current-doc stale operational labels: changelogs/README history excluded.
current_files=['MASTER.md','ACCESSIBILITY.md','AUTH_AND_LOGIN.md','COMPONENTS.md','DESIGN_REVIEW_CHECKLIST.md','I18N.md','IMPLEMENTATION_NOTES_VERCEL.md','PAGE_OVERRIDES_V1_8.md','PATTERNS.md','RESPONSIVE.md','SIDEBAR_NAVIGATION.md','TABLE_LAYOUT.md','TOKENS.md']
stale=[]
for f in current_files:
    for i,line in enumerate(t(f).splitlines(),1):
        if re.search(r'Desktop v1\.5|PAGE_OVERRIDES_V1_5|SIDEBAR.*v1\.5|current.*v1\.5',line,re.I): stale.append(f'{f}:{i}:{line}')
c('No stale v1.5 current operational labels',not stale,'; '.join(stale[:8]))

c('Root effective permissions visible','Root Admin:' in t('PAGE_OVERRIDES_V1_8.md') and 'Effective permissions' in t('PAGE_OVERRIDES_V1_8.md'))
c('Non-root other permissions hidden','Non-root Directory Manager' in t('PAGE_OVERRIDES_V1_8.md') and 'no other-user granular permission details' in t('PAGE_OVERRIDES_V1_8.md'))

# v1.8 owner-approved responsive UAT rules
c('Responsive prototype v1.10 authority','Responsive Prototype **v1.10**' in t('RESPONSIVE.md'))
c('Design README responsive v1.10 current','Responsive Prototype:** v1.10' in t('00_README.md') and 'Full Handover v1.18' in t('00_README.md'))
c('Status badge 144px benchmark','144px' in t('RESPONSIVE.md') and '144px' in t('PAGE_OVERRIDES_V1_8.md'))
c('Status menu anchored to trigger','anchored to the status badge/button bounds' in t('RESPONSIVE.md') and 'must not use the exact pointer click coordinates' in t('PATTERNS.md'))
c('Status menu dismiss + focus restore','Escape restores focus' in t('RESPONSIVE.md') and 'same-trigger toggle' in t('PATTERNS.md'))
c('Interview time-first responsive','time first, date after' in t('RESPONSIVE.md') and 'time-first' in t('PAGE_OVERRIDES_V1_8.md'))
c('Mobile interview time label width','Thời gian phỏng vấn' in t('RESPONSIVE.md') and 'avoid unnecessary wrapping' in t('RESPONSIVE.md'))
c('Mobile nav accessibility','background inertness/scroll lock' in t('RESPONSIVE.md') and 'focus restoration' in t('ACCESSIBILITY.md'))

passed=sum(ok for ok,_,_ in r); failed=len(r)-passed
out=['DESIGN VALIDATION — EIU Recruitment Design System v1.8 — 2026-09-03',f'TOTAL={len(r)} PASS={passed} FAIL={failed}','']
for ok,n,d in r: out.append(f"{'PASS' if ok else 'FAIL'} | {n}"+(f' | {d}' if d else ''))
if not a.no_write:
    (B/'DESIGN_VALIDATION.txt').write_text('\n'.join(out)+'\n')
print('\n'.join(out)); sys.exit(1 if failed else 0)
