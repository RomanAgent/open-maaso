using System;
using System.Collections.Generic;
using UnityEngine;
using Maaso.World;

namespace Maaso.Avatar
{
    /// <summary>Scene-local union floor and reviewed obstacle footprint routing.
    /// It cannot fill the missing northwest corner with a rectangular fallback.</summary>
    public sealed class PersonalSpaceNavigation : MonoBehaviour
    {
        public string Revision;
        public int LayoutRevision;
        public string LayoutDigest;
        public WorldMapPlayableBounds ContractBedBounds;
        public Bounds[] WalkableRegions = Array.Empty<Bounds>();
        public Bounds[] Obstacles = Array.Empty<Bounds>();
        public Transform[] RouteNodes = Array.Empty<Transform>();
        public Bounds BedroomPortal;
        public PersonalSpacePocketDoor BedroomDoor;
        public float ActorRadius = .18f;

        public bool ContainsCamera(Vector3 world,float clearance=.08f)
        {
            Vector3 point=transform.InverseTransformPoint(world);
            if(!Finite(point)||point.y<clearance||point.y>3.2f-clearance)return false;
            for(int i=-1;i<16;i++)
            {
                Vector3 sample=point;
                if(i>=0){float angle=i*Mathf.PI/8;sample.x+=Mathf.Cos(angle)*clearance;sample.z+=Mathf.Sin(angle)*clearance;}
                bool inside=false;
                foreach(var region in WalkableRegions)
                    if(sample.x>=region.min.x&&sample.x<=region.max.x&&sample.z>=region.min.z&&sample.z<=region.max.z)
                    {
                        // The thin union connector is a real doorway, not an
                        // opening all the way through the ceiling/header.
                        if(region.size.x<.5f&&point.y+clearance>BedroomPortal.max.y)continue;
                        inside=true;break;
                    }
                if(!inside)return false;
            }
            foreach(var obstacle in Obstacles)
                if((point-obstacle.ClosestPoint(point)).sqrMagnitude<clearance*clearance)return false;
            return true;
        }
        public bool CameraSegmentIsClear(Vector3 from,Vector3 to,float clearance=.08f)
        {
            if(!Finite(from)||!Finite(to))return false;
            float distance=Vector3.Distance(from,to);if(distance>40)return false;
            int steps=Mathf.Max(1,Mathf.CeilToInt(distance/.04f));
            for(int i=0;i<=steps;i++)if(!ContainsCamera(Vector3.Lerp(from,to,(float)i/steps),clearance))return false;
            return true;
        }
        public bool TryBuildCameraRoute(Vector3 from,Vector3 destination,out List<Vector3> route)
            =>BuildCameraRoute(from,destination,null,out route);
        public bool TryBuildCameraRouteAroundSubject(Vector3 from,Vector3 destination,Bounds subject,out List<Vector3> route)
            =>BuildCameraRoute(from,destination,subject,out route);
        public bool CameraSegmentAvoidsSubject(Vector3 from,Vector3 to,Bounds subject)
        {
            if(!CameraSegmentIsClear(from,to))return false;
            subject.Expand(.16f);
            if(subject.Contains(from))
            {
                Vector3 away=from-subject.center,move=to-from;away.y=move.y=0;
                return Vector3.Dot(away,move)>=0&&(away+move).sqrMagnitude>away.sqrMagnitude;
            }
            if(subject.Contains(to))return false;
            Vector3 delta=to-from;
            return delta.sqrMagnitude<.000001f||!subject.IntersectRay(new Ray(from,delta.normalized),out float distance)||distance>delta.magnitude;
        }
        private bool BuildCameraRoute(Vector3 from,Vector3 destination,Bounds? subject,out List<Vector3> route)
        {
            route=new List<Vector3>();
            if(!gameObject.activeInHierarchy||string.IsNullOrWhiteSpace(Revision)||!ContainsCamera(from)||!ContainsCamera(destination))return false;
            Bounds expanded=subject??default;expanded.Expand(.16f);
            if(subject.HasValue&&expanded.Contains(destination))return false;
            var nodes=new List<Vector3>{from,destination};
            foreach(var node in RouteNodes)
            {
                if(node==null||!node.IsChildOf(transform))continue;
                var local=transform.InverseTransformPoint(node.position);local.y=1.4f;
                var at=transform.TransformPoint(local);if(ContainsCamera(at)&&(!subject.HasValue||!expanded.Contains(at)))nodes.Add(at);
            }
            if(subject.HasValue)
                foreach(float x in new[]{BedroomPortal.min.x-.25f,BedroomPortal.max.x+.25f})
                foreach(float z in new[]{BedroomPortal.min.z+.12f,BedroomPortal.max.z-.12f})
                {var at=transform.TransformPoint(new Vector3(x,1.4f,z));if(ContainsCamera(at)&&!expanded.Contains(at))nodes.Add(at);}
            if(nodes.Count>64)return false;
            var costs=new float[nodes.Count];var previous=new int[nodes.Count];var visited=new bool[nodes.Count];
            for(int i=0;i<nodes.Count;i++){costs[i]=float.PositiveInfinity;previous[i]=-1;}costs[0]=0;
            for(int iteration=0;iteration<nodes.Count;iteration++)
            {
                int current=-1;float best=float.PositiveInfinity;
                for(int i=0;i<nodes.Count;i++)if(!visited[i]&&costs[i]<best){current=i;best=costs[i];}
                if(current<0)break;
                if(current==1){for(int at=1;at!=0;at=previous[at]){if(at<0)return false;route.Add(nodes[at]);}route.Reverse();return true;}
                visited[current]=true;
                for(int next=0;next<nodes.Count;next++)
                {
                    if(visited[next]||next==current||!(subject.HasValue?CameraSegmentAvoidsSubject(nodes[current],nodes[next],subject.Value):CameraSegmentIsClear(nodes[current],nodes[next])))continue;
                    float cost=best+Vector3.Distance(nodes[current],nodes[next]);
                    if(cost<costs[next]){costs[next]=cost;previous[next]=current;}
                }
            }
            return false;
        }

        public bool ContainsFoot(Vector3 world)
        {
            Vector3 point=transform.InverseTransformPoint(world);
            if (!Finite(point)) return false;
            for(int i=-1;i<8;i++)
            {
                Vector3 sample=point;
                if(i>=0) {float angle=i*Mathf.PI*.25f;sample.x+=Mathf.Cos(angle)*ActorRadius;sample.z+=Mathf.Sin(angle)*ActorRadius;}
                bool inside=false;
                foreach(var region in WalkableRegions)
                    if(sample.x>=region.min.x && sample.x<=region.max.x && sample.z>=region.min.z && sample.z<=region.max.z) {inside=true;break;}
                if(!inside) return false;
            }
            foreach(var obstacle in Obstacles)
            {
                if(obstacle.max.y<.12f || obstacle.min.y>2.05f) continue;
                float x=Mathf.Clamp(point.x,obstacle.min.x,obstacle.max.x),z=Mathf.Clamp(point.z,obstacle.min.z,obstacle.max.z);
                if((point.x-x)*(point.x-x)+(point.z-z)*(point.z-z)<ActorRadius*ActorRadius) return false;
            }
            return true;
        }
        public bool SegmentIsClear(Vector3 from,Vector3 to)
        {
            float distance=Vector3.Distance(from,to);
            if(!Finite(from) || !Finite(to) || distance>40) return false;
            int steps=Mathf.Max(1,Mathf.CeilToInt(distance/.08f));
            for(int i=0;i<=steps;i++) if(!ContainsFoot(Vector3.Lerp(from,to,(float)i/steps))) return false;
            return true;
        }
        public bool TryBuildRoute(Vector3 from,Vector3 destination,IReadOnlyList<Transform> hints,out List<Vector3> route)
        {
            route=new List<Vector3>();
            if(!gameObject.activeInHierarchy || string.IsNullOrWhiteSpace(Revision) || !ContainsFoot(from) || !ContainsFoot(destination)) return false;
            var nodes=new List<Vector3>{from,destination};
            void Add(Transform value) {if(value!=null && (value==transform || value.IsChildOf(transform)) && ContainsFoot(value.position)) nodes.Add(value.position);}
            foreach(var node in RouteNodes) Add(node);
            if(hints!=null) foreach(var node in hints) Add(node);
            if(nodes.Count>64) return false;
            var costs=new float[nodes.Count];var previous=new int[nodes.Count];var visited=new bool[nodes.Count];
            for(int i=0;i<nodes.Count;i++) {costs[i]=float.PositiveInfinity;previous[i]=-1;}
            costs[0]=0;
            for(int iteration=0;iteration<nodes.Count;iteration++)
            {
                int current=-1;float best=float.PositiveInfinity;
                for(int i=0;i<nodes.Count;i++) if(!visited[i] && costs[i]<best) {current=i;best=costs[i];}
                if(current<0) break;
                if(current==1) {for(int at=1;at!=0;at=previous[at]) {if(at<0)return false;route.Add(nodes[at]);}route.Reverse();return true;}
                visited[current]=true;
                for(int next=0;next<nodes.Count;next++)
                {
                    if(visited[next] || next==current || !SegmentIsClear(nodes[current],nodes[next])) continue;
                    float cost=best+Vector3.Distance(nodes[current],nodes[next]);
                    if(cost<costs[next]) {costs[next]=cost;previous[next]=current;}
                }
            }
            return false;
        }
        public bool CrossesBedroomPortal(Vector3 from,IReadOnlyList<Vector3> route)
        {
            Vector3 previous=transform.InverseTransformPoint(from);previous.y=BedroomPortal.center.y;
            foreach(var world in route)
            {
                Vector3 next=transform.InverseTransformPoint(world);next.y=BedroomPortal.center.y;Vector3 delta=next-previous;
                if(BedroomPortal.Contains(previous) || BedroomPortal.Contains(next) ||
                    (delta.sqrMagnitude>.0001f && BedroomPortal.IntersectRay(new Ray(previous,delta.normalized),out float distance) && distance<=delta.magnitude)) return true;
                previous=next;
            }
            return false;
        }
        private static bool Finite(Vector3 value)=>!float.IsNaN(value.x)&&!float.IsNaN(value.y)&&!float.IsNaN(value.z)&&!float.IsInfinity(value.x)&&!float.IsInfinity(value.y)&&!float.IsInfinity(value.z);
    }
}
