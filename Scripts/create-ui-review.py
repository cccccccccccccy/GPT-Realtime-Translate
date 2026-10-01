"""Generate synthetic, local-only material for the isolated native UI review app."""
import json
import plistlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
app = root / "build/ResearchCopilotReview.app/Contents"
plist_path = app / "Info.plist"
with plist_path.open("rb") as handle:
    plist = plistlib.load(handle)
plist.update(CFBundleIdentifier="org.researchcopilot.review",
             CFBundleDisplayName="科研副驾界面验证", CFBundleName="ResearchCopilotReview",
             ResearchCopilotUIReview=True)
with plist_path.open("wb") as handle:
    plistlib.dump(plist, handle)

def segment(index, text, track="remote"):
    return dict(id=f"review-{index:02d}", track=track, start=index * 20,
                end=index * 20 + 8, text=text, revision=1, isFinal=True,
                manuallyCorrected=False)

segments = [
    segment(0, "What is the rationale for selecting this time point?"),
    segment(1, "We plan to compare imaging findings with histology.", "microphone"),
    segment(2, "You could consider another control group, but this is only a proposal."),
]
segments[0]["timingApproximate"] = True
for index in range(3, 23):
    segments.append(segment(index, f"Synthetic discussion segment {index}: this demonstration contains no experimental results or real participants."))
segments += [
    segment(23, "How will you distinguish reversible ischemia from actual necrosis?"),
    segment(24, "The detailed validation protocol needs confirmation.", "microphone"),
    segment(25, "We agree to prepare a list of unresolved questions. We have not assigned an owner or a deadline."),
]
fact = dict(id="review-plan", content="Compare imaging findings with histology.",
            kind="confirmedPlan", origin="虚构研究计划")
profile = dict(identity="Synthetic researcher", project="仅用于界面验证的虚构会议",
               facts=[fact], terminology="histology / 组织学")
answer = dict(id="review-answer", createdAt=811209601,
              sources=[dict(id="review-00", revision=1)],
              content=dict(sourceIDs=["review-00"], factIDs=[fact["id"]],
                           coreQuestion="时间点选择依据", intent="解释研究计划",
                           english="We plan to compare imaging findings with histology.",
                           chinese="我们计划将影像学发现与组织学进行比较。",
                           shortAnswer="We plan a histology comparison.",
                           cautiousAnswer="The time point rationale needs confirmation.",
                           clarification="Which part of the rationale would you like us to clarify?",
                           missingInformation=["未提供时间点选择的具体依据。"], warnings=[]),
              provider="虚构示例", model="不调用模型", pinned=True, stale=False,
              evidenceSegments=[segments[0]], evidenceFacts=[fact])

def entry(text, *indices):
    return dict(text=text, sourceIDs=[f"review-{i:02d}" for i in indices], owner=None, deadline=None)

summary = dict(topics=[entry("讨论时间点选择和组织学验证。", 0, 1)],
               questions=[entry("如何区分可逆缺血与实际坏死？", 23)],
               actualAnswers=[entry("用户说明计划比较影像学与组织学。", 1)],
               decisions=[], actions=[entry("整理尚未解决的问题清单。", 25)],
               unresolved=[entry("增加对照组仍是备选建议，尚未确认接受。", 2)])
meeting = dict(schemaVersion=1, id="A164A003-AF00-4567-9876-AABBCCDD0011",
               title="虚构会议 · 来源追溯验证", startedAt=811209600, endedAt=811210130,
               microphoneIncluded=True, configuration="isolated-ui-review",
               segments=segments, answers=[answer], summary=summary,
               summaryEvidence=[segments[i] for i in [0, 1, 2, 23, 25]],
               summaryStale=False, gaps=[], profile=profile)
(app / "Resources/UIReviewMeeting.json").write_text(
    json.dumps(meeting, ensure_ascii=False, indent=2) + "\n")
print("Prepared isolated synthetic UI review bundle")
