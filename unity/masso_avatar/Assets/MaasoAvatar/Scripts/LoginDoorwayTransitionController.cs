using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using Maaso.World;
using UnityEngine;

namespace Maaso.Avatar
{
    [Serializable]
    public sealed class LoginDoorwayCommand
    {
        public string requestId, transitionId, phase;
        public int durationMs;
        public long sequence, expiresAtMs;
    }

    [Serializable]
    public sealed class LoginDoorwayResult
    {
        public string method = "transitionLoginDoorway";
        public string requestId, transitionId, phase, code;
        public bool ok;
    }

    /// <summary>One fenced camera owner. It never moves or replaces the Avatar.</summary>
    public sealed class LoginDoorwayTransitionController
    {
        private readonly Action<LoginDoorwayResult> report;
        private readonly Dictionary<string, LoginDoorwayResult> receipts = new();
        private readonly HashSet<string> retired = new();
        private string transitionId, lastPhase;
        private long sequence;
        private Camera camera;
        private FrontFullBodyCamera framing;
        private LoginDoorwayRig rig;
        private LoginDoorwayCommand pending;
        private float startedAt;
        private long doorLease;
        private Vector3 entryDestination, entryLookTarget;
        private Quaternion entryRotation;
        private float entryFieldOfView;
        private Vector3 savedPosition, finalPosition, finalLookTarget;
        private Quaternion savedRotation, exteriorRotation, finalRotation;
        private float savedFieldOfView, finalFieldOfView, savedAspect;
        private Rect savedRect;
        private bool savedFramingEnabled;
        private string savedFramingMode;
        private string finalFramingMode;
        private PersonalSpaceNavigation followNavigation;
        private Transform followedAvatar;
        private List<Vector3> followPath;
        private float followLength,followStarted=-1;
        private bool waitingForBedroomDoor;
        public bool OwnsCamera { get; private set; }
        public string TransitionId => transitionId;

        public LoginDoorwayTransitionController(Action<LoginDoorwayResult> report) => this.report = report;

        public void Execute(LoginDoorwayCommand command, FrontFullBodyCamera view,
            LoginDoorwayRig doorway, bool canPresent, float now, long utcMs)
        {
            if (!Valid(command) || command.expiresAtMs <= utcMs)
            { Reply(command, false, "invalid_or_expired_request"); return; }
            if (receipts.TryGetValue(command.requestId, out LoginDoorwayResult duplicate))
            { report(duplicate); return; }
            if (retired.Contains(command.transitionId))
            { Reply(command, false, "transition_retired"); return; }
            if (transitionId != command.transitionId)
            {
                if (command.phase != "prepare" || OwnsCamera || !canPresent || view == null || doorway == null || !doorway.IsReady)
                { Reply(command, false, "presentation_unavailable"); return; }
                framing = view; camera = view.GetComponent<Camera>(); rig = doorway;
                if (camera == null) { Reply(command, false, "camera_unavailable"); return; }
                if (!rig.TryAcquire(out doorLease)) { Reply(command,false,"entry_already_owned"); return; }
                transitionId = command.transitionId; sequence = 0; lastPhase = null;
                savedPosition = camera.transform.position; savedRotation = camera.transform.rotation;
                savedFieldOfView = camera.fieldOfView; savedRect = camera.rect; savedAspect = camera.aspect;
                savedFramingEnabled = framing.enabled; savedFramingMode = framing.FramingMode;
                OwnsCamera = true;
                framing.enabled = false;
                framing.BindEntrySafety(rig);
                finalFramingMode=framing.FramingMode=="sleeping_top"||
                    (framing.TargetRoot!=null&&Vector3.Dot(framing.TargetRoot.up,Vector3.up)<.5f)?"sleeping_top":"hero_full_body";
                framing.SetFramingMode(finalFramingMode);
                if (!framing.TryGetDoorwayFramingPose(rig,out CameraPose target, out finalFieldOfView))
                {
                    Restore(false); retired.Add(transitionId); Reply(command, false, "home_framing_unavailable"); return;
                }
                finalPosition = target.Position; finalRotation = target.Rotation;
                Vector3 finalForward = finalRotation * Vector3.forward;
                float focusDistance = Mathf.Max(.25f, Vector3.Dot(framing.DoorwaySubjectFocus - finalPosition, finalForward));
                finalLookTarget = finalPosition + finalForward * focusDistance;
                exteriorRotation = Quaternion.LookRotation(rig.DoorLookTarget.position - rig.ExteriorCamera.position, Vector3.up);
                entryDestination = rig.EntryDestination(finalPosition);
                entryLookTarget = rig.EntryLookTarget(finalLookTarget);
                entryFieldOfView = rig.EntryFieldOfView(finalFieldOfView);
                entryRotation = rig.IsSceneEntryBound ? rig.LobbyPose.Rotation : finalRotation;
                followNavigation=rig.Navigation;followedAvatar=framing.TargetRoot;followPath=null;followLength=0;followStarted=-1;
                if (followNavigation==null&&rig.MustHoldInLobby(framing.TargetRoot,finalPosition))
                {
                    finalPosition=entryDestination; finalRotation=entryRotation;
                    finalLookTarget=entryLookTarget; finalFieldOfView=entryFieldOfView;
                }
                if(followNavigation!=null)
                {
                    if(!followNavigation.TryBuildCameraRoute(entryDestination,finalPosition,out followPath))
                    {Restore(false);retired.Add(transitionId);Reply(command,false,"interior_camera_route_unavailable");return;}
                    Vector3 previous=entryDestination;foreach(var point in followPath){followLength+=Vector3.Distance(previous,point);previous=point;}
                    if(followLength>16.8f){Restore(false);retired.Add(transitionId);Reply(command,false,"interior_camera_route_too_long");return;}
                    // At Home, the lobby reference is only half a metre above
                    // the final full-body shot. End the entering camera curve
                    // at that same final pose, so frame never pulls back from
                    // a brief upper-body view. Longer bedroom/furniture routes
                    // still retain their separate navigated follow phase.
                    bool directHomeFinish=rig.IsSceneEntryBound&&finalFramingMode=="hero_full_body"&&
                        followLength<=.8f&&
                        Mathf.Abs(entryDestination.x-finalPosition.x)<.2f&&
                        Mathf.Abs(entryDestination.z-finalPosition.z)<.15f&&
                        !followNavigation.CrossesBedroomPortal(entryDestination,followPath)&&
                        followNavigation.CameraSegmentIsClear(entryDestination,finalPosition);
                    if(directHomeFinish)
                    {
                        entryDestination=finalPosition;entryLookTarget=finalLookTarget;
                        entryFieldOfView=finalFieldOfView;entryRotation=finalRotation;
                        followPath=new List<Vector3>{finalPosition};followLength=0;
                    }
                }
            }
            if (!OwnsCamera || rig == null || !rig.Owns(doorLease))
            { FailPending("entry_binding_retired"); Restore(false); retired.Add(transitionId); Reply(command,false,"entry_binding_retired"); return; }
            if (command.sequence <= sequence)
            { Reply(command, false, "stale_request"); return; }
            sequence = command.sequence;
            if (command.phase == "cancel")
            {
                FailPending("cancelled"); Restore(false); retired.Add(transitionId);
                Reply(command, true, ""); return;
            }
            if (command.phase == "skip")
            {
                FailPending("skipped"); SetFinal(); Restore(true); retired.Add(transitionId);
                Reply(command, true, ""); return;
            }
            if (!canPresent)
            { FailPending("presentation_revoked"); Restore(false); retired.Add(transitionId); Reply(command, false, "presentation_revoked"); return; }
            bool legal = command.phase switch
            {
                "prepare" => lastPhase == null,
                "open" => lastPhase == "prepare",
                "enter" => lastPhase == "open",
                "frame" => lastPhase == "enter",
                _ => false,
            };
            if (!legal || pending != null)
            { Reply(command, false, "invalid_phase"); return; }
            if (command.phase == "prepare")
            {
                rig.SetOpen(doorLease,0); SetViewport(.48f);
                camera.fieldOfView = 55f;
                camera.transform.SetPositionAndRotation(rig.ExteriorCamera.position, exteriorRotation);
                lastPhase = "prepare"; Reply(command, true, ""); return;
            }
            pending = command; startedAt = now;
            if(command.phase=="frame"&&followNavigation!=null)
            {
                waitingForBedroomDoor=followNavigation.CrossesBedroomPortal(entryDestination,followPath);
                if(waitingForBedroomDoor&&(followNavigation.BedroomDoor==null||!followNavigation.BedroomDoor.RequestOpen()))
                {FailPending("bedroom_door_unavailable");Restore(false);retired.Add(transitionId);return;}
                followStarted=-1;
            }
            Advance(now, utcMs);
        }

        public void Advance(float now, long utcMs)
        {
            if (pending == null) return;
            if (!OwnsCamera || camera == null || rig == null || !rig.Owns(doorLease) || utcMs >= pending.expiresAtMs)
            { FailPending("presentation_interrupted"); Restore(false); return; }
            if(pending.phase=="frame"&&followNavigation!=null){AdvanceFollowPath(now);return;}
            float elapsed = Mathf.Max(0, now - startedAt);
            float duration = pending.durationMs * .001f;
            float progress = duration <= 0 || elapsed >= duration || Mathf.Approximately(elapsed, duration)
                ? 1 : Mathf.Clamp01(elapsed / duration);
            float eased = Mathf.SmoothStep(0, 1, progress);
            const float openingTravel = .20f;
            switch (pending.phase)
            {
                case "open":
                    rig.SetOpen(doorLease,eased);
                    SetViewport(.48f + .52f * eased);
                    Vector3 openingPosition = rig.CameraPosition(openingTravel * eased, entryDestination);
                    Vector3 openingLook = Vector3.Lerp(rig.DoorLookTarget.position, entryLookTarget, openingTravel * eased);
                    camera.transform.SetPositionAndRotation(openingPosition,
                        Quaternion.LookRotation(openingLook - openingPosition, Vector3.up));
                    break;
                case "enter":
                    Vector3 position = rig.CameraPosition(openingTravel + (1 - openingTravel) * eased, entryDestination);
                    float lookProgress = openingTravel + (1 - openingTravel) * (1 - (1 - eased) * (1 - eased));
                    Vector3 lookAt = Vector3.Lerp(rig.DoorLookTarget.position, entryLookTarget, lookProgress);
                    camera.transform.SetPositionAndRotation(position,
                        Quaternion.LookRotation(lookAt - position, Vector3.up));
                    camera.fieldOfView = Mathf.Lerp(DoorwayFieldOfView(1), entryFieldOfView, eased);
                    break;
                case "frame":
                    rig.SetOpen(doorLease,1-eased); SetViewport(1);
                    camera.fieldOfView=Mathf.Lerp(entryFieldOfView,finalFieldOfView,eased);
                    camera.transform.SetPositionAndRotation(Vector3.Lerp(entryDestination,finalPosition,eased),
                        Quaternion.Slerp(entryRotation,finalRotation,eased));
                    break;
            }
            if (progress < 1) return;
            LoginDoorwayCommand done = pending; pending = null; lastPhase = done.phase;
            if (done.phase == "frame")
            {
                framing.CompleteDoorwayCameraRoute(rig);
                Restore(true); retired.Add(transitionId);
            }
            Reply(done, true, "");
        }

        public void CancelForReset(string reason)
        {
            if (!OwnsCamera) return;
            FailPending(reason);
            if (transitionId != null) retired.Add(transitionId);
            Restore(false);
        }

        private void SetFinal()
        {
            if (camera == null || rig == null || !rig.Owns(doorLease)) return;
            rig.SetOpen(doorLease,0); SetViewport(1);
            camera.fieldOfView = finalFieldOfView;
            camera.transform.SetPositionAndRotation(finalPosition, finalRotation);
            if(followNavigation!=null)framing.CompleteDoorwayCameraRoute(rig);
        }

        private void AdvanceFollowPath(float now)
        {
            if(framing.TargetRoot!=followedAvatar||rig.Navigation!=followNavigation||followPath==null)
            {FailPending("interior_camera_route_retired");Restore(false);return;}
            // Enter already put the lens inside the room. Close behind it in
            // 300ms even when the bedroom door or a long follow route delays
            // the final framing handoff.
            rig.SetOpen(doorLease,1-Mathf.SmoothStep(0,1,Mathf.Clamp01((now-startedAt)/.3f)));
            if(waitingForBedroomDoor)
            {
                if(!followNavigation.BedroomDoor.Ready||now-startedAt>2)
                {FailPending("bedroom_door_timeout");Restore(false);return;}
                if(!followNavigation.BedroomDoor.IsOpen)return;
                waitingForBedroomDoor=false;
            }
            if(followStarted<0)followStarted=now;
            float duration=Mathf.Max(pending.durationMs*.001f,followLength/1.4f);
            float t=duration<=0?1:Mathf.Clamp01((now-followStarted)/duration);
            float eased=Mathf.SmoothStep(0,1,t),distance=followLength*eased;
            Vector3 position=PointAlongFollowPath(distance);
            if(!followNavigation.CameraSegmentIsClear(camera.transform.position,position)||
                (followNavigation.CrossesBedroomPortal(camera.transform.position,new[]{position})&&!followNavigation.BedroomDoor.IsOpen))
            {FailPending("interior_camera_path_blocked");Restore(false);return;}
            // The lens looks at the subject, not at an upward segment leading
            // to the overhead endpoint; that segment would show only ceiling.
            Vector3 toSubject=finalLookTarget-position;
            Vector3 viewUp=Mathf.Abs(Vector3.Dot(toSubject.normalized,Vector3.up))>.96f?Vector3.back:Vector3.up;
            Quaternion routeRotation=toSubject.sqrMagnitude>.0001f?Quaternion.LookRotation(toSubject,viewUp):finalRotation;
            routeRotation=Quaternion.Slerp(entryRotation,routeRotation,Mathf.SmoothStep(0,1,Mathf.Clamp01(t*4)));
            routeRotation=Quaternion.Slerp(routeRotation,finalRotation,Mathf.SmoothStep(0,1,Mathf.InverseLerp(.7f,1,t)));
            SetViewport(1);
            camera.fieldOfView=Mathf.Lerp(entryFieldOfView,finalFieldOfView,eased);
            camera.transform.SetPositionAndRotation(position,routeRotation);
            if(t<1)return;
            framing.CompleteDoorwayCameraRoute(rig);
            LoginDoorwayCommand done=pending;pending=null;lastPhase=done.phase;
            Restore(true);retired.Add(transitionId);Reply(done,true,"");
        }
        private Vector3 PointAlongFollowPath(float distance)
        {
            Vector3 previous=entryDestination;
            foreach(var point in followPath)
            {
                float segment=Vector3.Distance(previous,point);
                if(distance<=segment)return segment<.00001f?point:Vector3.Lerp(previous,point,distance/segment);
                distance-=segment;previous=point;
            }
            return finalPosition;
        }

        private void Restore(bool keepFinal)
        {
            if (!OwnsCamera) return;
            if (camera != null && !keepFinal)
            {
                camera.transform.SetPositionAndRotation(savedPosition, savedRotation);
                camera.fieldOfView = savedFieldOfView; camera.rect = savedRect; camera.aspect = savedAspect;
                // Only the exact still-current lease may restore its acquired door state.
            }
            if (framing != null)
            {
                framing.SetFramingMode(keepFinal ? finalFramingMode : savedFramingMode);
                framing.enabled = savedFramingEnabled;
            }
            rig?.Release(doorLease,!keepFinal);
            doorLease=0;
            OwnsCamera = false;
        }

        private void FailPending(string reason)
        {
            if (pending == null) return;
            LoginDoorwayCommand previous = pending; pending = null; Reply(previous, false, reason);
        }

        private void SetViewport(float height)
        {
            camera.rect = new Rect(0, 1 - height, 1, height);
            camera.aspect = savedAspect / height;
            // Expanding the viewport reveals more vertical space; it must not
            // crop/zoom the door sideways before the camera passes through it.
            camera.fieldOfView = DoorwayFieldOfView(height);
        }

        private static float DoorwayFieldOfView(float height) =>
            2f * Mathf.Atan(Mathf.Tan(55f * Mathf.Deg2Rad * .5f) * height / .48f) * Mathf.Rad2Deg;

        private void Reply(LoginDoorwayCommand command, bool ok, string code)
        {
            var result = new LoginDoorwayResult { requestId = command?.requestId,
                transitionId = command?.transitionId, phase = command?.phase, ok = ok, code = code };
            if (!string.IsNullOrEmpty(result.requestId)) receipts[result.requestId] = result;
            report(result);
        }
        private static bool Valid(LoginDoorwayCommand command)
        {
            const string identifier = "^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$";
            return command != null && !string.IsNullOrEmpty(command.requestId) && !string.IsNullOrEmpty(command.transitionId) &&
                Regex.IsMatch(command.requestId, identifier) && Regex.IsMatch(command.transitionId, identifier) &&
                command.durationMs >= 0 && command.durationMs <= 4000 && command.sequence > 0 &&
                command.phase is "prepare" or "open" or "enter" or "frame" or "skip" or "cancel";
        }
    }
}
