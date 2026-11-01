using System;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Aligns the movable chair with the actual reviewed keyboard.
    /// The laptop and its baked tabletop shadows stay at their authored location.</summary>
    public sealed class AvatarDeskWorkLayout : IDisposable
    {
        private readonly AvatarFurnitureRig rig;
        private Transform chair,seat,approach,surface;
        private Vector3 chairPosition,seatPosition,approachPosition,surfacePosition;
        private Bounds[] originalObstacles,alignedObstacles;
        private Bounds localKeyboard;
        public bool Ready { get; private set; }
        public Bounds KeyboardBounds
        {
            get
            {
                Bounds result = new(rig.transform.TransformPoint(localKeyboard.center), Vector3.zero);
                for (int x = -1; x <= 1; x += 2)
                for (int y = -1; y <= 1; y += 2)
                for (int z = -1; z <= 1; z += 2)
                    result.Encapsulate(rig.transform.TransformPoint(localKeyboard.center + Vector3.Scale(localKeyboard.extents, new Vector3(x, y, z))));
                return result;
            }
        }

        public AvatarDeskWorkLayout(AvatarFurnitureRig owner) { rig = owner; }

        public bool Align()
        {
            if (Ready) return true;
            AvatarFurnitureAnchor desk = rig.Find("desk");
            if (desk?.Seat == null || desk.Approach == null || desk.WorkSurface == null) return false;
            MeshFilter deskMesh = null;
            foreach (MeshFilter item in rig.GetComponentsInChildren<MeshFilter>(true))
            {
                if (item.name == "V4_WorkDesk_Baked") deskMesh = item;
                if (item.name == "V4_WorkChair_Baked") chair = item.transform;
            }
            if (deskMesh?.sharedMesh == null || chair == null) return false;
            // The Editor/build hook fingerprints the FBX and copies only this
            // desk, preserving the rest of the room's GPU-only mesh imports.
            Mesh sourceMesh = Resources.Load<Mesh>("MaasoDeskWorkMesh");
            if (sourceMesh == null || !sourceMesh.isReadable ||
                sourceMesh.vertexCount != deskMesh.sharedMesh.vertexCount ||
                sourceMesh.subMeshCount != deskMesh.sharedMesh.subMeshCount ||
                sourceMesh.bounds != deskMesh.sharedMesh.bounds) return false;
            // Read only the actual keys; no source vertices, laptop transform,
            // materials or baked shadows are changed.
            Bounds keyRegion = new(new Vector3(-2.47f, .761f, 3.083f), new Vector3(.322f, .006f, .108f));
            Vector3[] vertices = sourceMesh.vertices;
            Bounds keys = default;
            int keyCount = 0;
            foreach (Vector3 vertex in vertices)
            {
                Vector3 point = rig.transform.InverseTransformPoint(deskMesh.transform.TransformPoint(vertex));
                if (!keyRegion.Contains(point)) continue;
                if (keyCount++ == 0) keys = new Bounds(point, Vector3.zero); else keys.Encapsulate(point);
            }
            if (keyCount < 32) return false;
            seat=desk.Seat;approach=desk.Approach;surface=desk.WorkSurface;
            Vector3 seatLocal=rig.transform.InverseTransformPoint(seat.position);
            Vector3 correction=rig.transform.TransformVector(new Vector3(keys.center.x-seatLocal.x,0,.24f));
            chairPosition=chair.localPosition;seatPosition=seat.localPosition;
            approachPosition=approach.localPosition;surfacePosition=surface.localPosition;
            if(rig.Navigation!=null)
            {
                originalObstacles=rig.Navigation.Obstacles;
                alignedObstacles=(Bounds[])originalObstacles.Clone();
                Vector3 centre=rig.Navigation.transform.InverseTransformPoint(chair.GetComponent<Renderer>().bounds.center);
                Vector3 delta=rig.Navigation.transform.InverseTransformVector(correction);
                int matches=0;
                for(int i=0;i<alignedObstacles.Length;i++)
                {
                    if(Vector3.Distance(alignedObstacles[i].center,centre)>.01f)continue;
                    Bounds moved=alignedObstacles[i];moved.center+=delta;alignedObstacles[i]=moved;matches++;
                }
                if(matches!=1)return false;
                rig.Navigation.Obstacles=alignedObstacles;
            }
            chair.position+=correction;seat.position+=correction;approach.position+=correction;
            localKeyboard = keys;
            desk.WorkSurface.position = rig.transform.TransformPoint(new Vector3(localKeyboard.center.x, localKeyboard.max.y, localKeyboard.center.z));
            Ready = true;
            return true;
        }

        public void Dispose()
        {
            if(Ready)
            {
                if(chair!=null)chair.localPosition=chairPosition;
                if(seat!=null)seat.localPosition=seatPosition;
                if(approach!=null)approach.localPosition=approachPosition;
                if(surface!=null)surface.localPosition=surfacePosition;
                if(rig!=null && rig.Navigation!=null && rig.Navigation.Obstacles==alignedObstacles)
                    rig.Navigation.Obstacles=originalObstacles;
            }
            originalObstacles=alignedObstacles=null;Ready=false;
        }
    }
}
