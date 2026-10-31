# Puck enclosure ESP32 DevKit V1 (30-pin USB-C) + INMP441 bulat. Versi v3: dudukan jepit tepi.
# Satuan mm. z = 0 di dasar luar badan. Port USB menghadap +X, mic di sisi +Y.
# Desain sengaja toleran: board 50-52,5 x 26-28,5 mm, mic Ø13-15 mm, tanpa butuh posisi lubang baut.
# Jalankan: Blender --background --python puck.py, atau buka di tab Scripting Blender lalu Run Script.
import bpy, bmesh, math, os, struct
from mathutils import Matrix
from mathutils.bvhtree import BVHTree

P = dict(
    OD=66.0, wall=2.4, floor=2.0, H=30.0, lid_t=2.0,
    lap_h=3.0, lap_wall=1.2, fit=0.2,            # sambungan tumpang badan-tutup
    chamfer_bot=0.6, chamfer_top=1.5,
    pcb_L_max=52.5, pcb_W_max=28.5, pcb_t=1.6, corner_clear=0.4,
    under_pcb=19.0,                              # lantai dalam -> bawah PCB (lekuk 2.5 + Dupont 14 + header 2.5)
    usb_w=14.0, usb_bottom=19.5,                 # U-notch, z dari dasar luar
    mic_ring_d=15.2, mic_ring_wall=1.2, mic_ring_h=2.4, mic_x=0.0, mic_y=21.3,
    grille_r=2.2, grille_hole=1.4,               # 1 lubang tengah + 6 melingkar
    seg=192,
    out=os.path.expanduser('~/Desktop/3d-models/puck'),
)

R = P['OD'] / 2
Ri = R - P['wall']
Z_BODY = P['H'] - P['lid_t']          # bibir atas badan = bawah pelat tutup
Z_LAP = Z_BODY - P['lap_h']
R_LAP = Ri + P['lap_wall']
R_SKIRT_IN = R_LAP + P['fit']
X_USB = math.sqrt((Ri - P['corner_clear']) ** 2 - (P['pcb_W_max'] / 2) ** 2)   # tepi PCB sisi USB
X_ANT_MAX = X_USB - P['pcb_L_max']                                                 # tepi antena board terpanjang
Z_PCB = P['floor'] + P['under_pcb']
Z_PCB_TOP = Z_PCB + P['pcb_t']
GUIDE_Y = P['pcb_W_max'] / 2 + 0.2
SNAP_ANGLES = (90, 210, 330)
SNAP_Z = Z_LAP + 1.6


# ---------- primitif ----------
def _new(name, bm, coll):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    coll.objects.link(ob)
    return ob


def cyl(name, coll, r0, z0, z1, x=0.0, y=0.0, r1=None, seg=None):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=seg or P['seg'],
                          radius1=r0, radius2=r0 if r1 is None else r1, depth=z1 - z0,
                          matrix=Matrix.Translation((x, y, (z0 + z1) / 2)))
    return _new(name, bm, coll)


def box(name, coll, x0, x1, y0, y1, z0, z1):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0, matrix=Matrix.Translation(((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2))
                          @ Matrix.Diagonal((x1 - x0, y1 - y0, z1 - z0, 1)))
    return _new(name, bm, coll)


def sphere(name, coll, r, x, y, z):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=24, v_segments=12, radius=r, matrix=Matrix.Translation((x, y, z)))
    return _new(name, bm, coll)


def polar(r, deg):
    a = math.radians(deg)
    return r * math.cos(a), r * math.sin(a)


def boolean(target, tools, op):
    for t in tools:
        m = target.modifiers.new('b', 'BOOLEAN')
        m.operation = op
        m.solver = 'EXACT'
        m.object = t
        dg = bpy.context.evaluated_depsgraph_get()
        me = bpy.data.meshes.new_from_object(target.evaluated_get(dg))
        target.modifiers.clear()
        old = target.data
        target.data = me
        bpy.data.meshes.remove(old)
        bpy.data.objects.remove(t)
    return target


def union_all(name, parts):
    base = parts[0]
    base.name = name
    return boolean(base, parts[1:], 'UNION')


# ---------- badan ----------
def build_body(c):
    shell = union_all('Puck_Body', [
        cyl('t', c, R - P['chamfer_bot'], 0, P['chamfer_bot'], r1=R),
        cyl('t', c, R, P['chamfer_bot'] - 0.01, Z_LAP),
        cyl('t', c, R_LAP, Z_LAP - 0.01, Z_BODY),
    ])
    boolean(shell, [cyl('t', c, Ri, P['floor'], Z_BODY + 1)], 'DIFFERENCE')

    f = P['floor'] - 0.2
    xa0, xa1 = X_USB - 5.5, X_USB - 1.0                  # blok sisi USB (di luar deret pin board 49,5-52,5 mm)
    xb0, xb1 = X_ANT_MAX + 1.4, X_ANT_MAX + 5.9          # blok sisi antena
    adds = [
        box('t', c, xa0, xa1, -12.5, 12.5, f, Z_PCB),
        box('t', c, xb0, xb1, -12.5, 12.5, f, Z_PCB),
        box('t', c, X_ANT_MAX - 1.6, X_ANT_MAX - 0.3, -8, 8, f, Z_PCB_TOP + 0.6),   # stop ujung antena
    ]
    for s in (1, -1):                                     # pemandu samping
        for (x0, x1) in ((xa0, xa1), (xb0, xb1)):
            adds.append(box('t', c, x0, x1, s * GUIDE_Y, s * (GUIDE_Y + 1.2), f, Z_PCB_TOP + 0.6))
    for x in (-8.0, 8.0):                                 # tiang gulungan kabel
        adds.append(cyl('t', c, 1.5, f, P['floor'] + 13, x, -22.0, seg=32))
        adds.append(cyl('t', c, 2.6, P['floor'] + 12, P['floor'] + 13.2, x, -22.0, seg=32))
    for a in SNAP_ANGLES:                                 # tonjolan snap
        x, y = polar(R_LAP + 0.45 - 0.8, a)
        adds.append(sphere('t', c, 0.8, x, y, SNAP_Z))
    boolean(shell, adds, 'UNION')

    w = P['usb_w'] / 2
    boolean(shell, [
        box('t', c, Ri - 1, R + 1, -w, w, P['usb_bottom'], P['H'] + 1),              # U-notch USB
        box('t', c, -(R + 1), -(R_LAP - 0.6), -1.2, 1.2, Z_LAP, P['H'] + 1),          # alur kunci
        box('t', c, xa0 - 1, xa1 + 1, -5.0, 5.0, Z_PCB - 2.0, Z_PCB + 1),             # celah bawah port USB-C
    ], 'DIFFERENCE')
    return shell


# ---------- tutup ----------
def build_lid(c):
    z_skirt = Z_LAP + 0.2
    ct = P['chamfer_top']
    lid = union_all('Puck_Lid', [
        cyl('t', c, R, Z_BODY - 0.01, P['H'] - ct),
        cyl('t', c, R, P['H'] - ct - 0.01, P['H'], r1=R - ct),
        cyl('t', c, R, z_skirt, Z_BODY + 0.01),
    ])
    mx, my = P['mic_x'], P['mic_y']
    r_in = P['mic_ring_d'] / 2
    boolean(lid, [cyl('t', c, R_SKIRT_IN, z_skirt - 1, Z_BODY)], 'DIFFERENCE')        # rongga rok

    xp = X_ANT_MAX + 3.6
    adds = [
        cyl('t', c, r_in + P['mic_ring_wall'], Z_BODY - P['mic_ring_h'], Z_BODY + 0.01, mx, my, seg=96),
        box('t', c, -(R_SKIRT_IN + 0.05), -(R_LAP - 0.5), -1.0, 1.0, z_skirt, Z_BODY + 0.01),   # rusuk kunci
        cyl('t', c, 1.75, Z_PCB_TOP + 0.3, Z_BODY + 0.01, xp, 11.5, seg=32),                 # penekan PCB
        cyl('t', c, 1.75, Z_PCB_TOP + 0.3, Z_BODY + 0.01, xp, -11.5, seg=32),
    ]
    boolean(lid, adds, 'UNION')

    w = P['usb_w'] / 2
    cuts = [
        cyl('t', c, r_in, Z_BODY - P['mic_ring_h'] - 1, Z_BODY, mx, my, seg=96),       # dudukan mic
        cyl('t', c, P['grille_hole'] / 2, Z_BODY - 1, P['H'] + 1, mx, my, seg=24),     # grill mic tengah
        box('t', c, R_LAP - 0.5, R + 1, -w, w, z_skirt - 1, Z_BODY),                  # potongan rok di port USB
        box('t', c, -2.5, 2.5, -(R + 1), -(R_SKIRT_IN - 0.1), z_skirt - 1, z_skirt + 0.8),  # takik congkel
    ]
    for k in range(6):
        gx, gy = polar(P['grille_r'], 30 + k * 60)
        cuts.append(cyl('t', c, P['grille_hole'] / 2, Z_BODY - 1, P['H'] + 1, mx + gx, my + gy, seg=24))
    for a in SNAP_ANGLES:
        x, y = polar(R_LAP + 0.45 - 0.8, a)
        cuts.append(sphere('t', c, 0.9, x, y, SNAP_Z))
    boolean(lid, cuts, 'DIFFERENCE')
    return lid


# ---------- mock-up komponen (tidak diekspor) ----------
def build_mock(c, L, W, mic_d, tag=''):
    """Board diletakkan menempel sisi USB (ditekan dinding), sisa panjang diisi busa di ujung antena."""
    x_ant = X_USB - L
    xc = X_USB - L / 2

    def pin_x(i):
        return xc - 17.78 + (i - 1) * 2.54

    m = [box('Mock_PCB' + tag, c, x_ant, X_USB, -W / 2, W / 2, Z_PCB, Z_PCB_TOP),
         box('Mock_Module' + tag, c, x_ant, x_ant + 25.5, -9, 9, Z_PCB_TOP, Z_PCB_TOP + 3.1),
         box('Mock_USBC' + tag, c, X_USB + 0.6 - 7.35, X_USB + 0.6, -4.47, 4.47, Z_PCB_TOP - 1.4, Z_PCB_TOP + 3.2),
         box('Mock_Plug' + tag, c, X_USB + 0.6, X_USB + 25, -6, 6, Z_PCB_TOP + 1.6 - 3.25, Z_PCB_TOP + 1.6 + 3.25)]
    if L < P['pcb_L_max'] - 0.3:
        m.append(box('Mock_Foam' + tag, c, X_ANT_MAX - 0.3 + 0.05, x_ant - 0.05, -7, 7, Z_PCB, Z_PCB_TOP))
    for s in (1, -1):
        m.append(box('Mock_Button' + tag, c, X_USB - 7, X_USB - 2, s * 6.8, s * 10.3, Z_PCB_TOP, Z_PCB_TOP + 3.5))
        m.append(box('Mock_Header' + tag, c, pin_x(1) - 1.27, pin_x(15) + 1.27, s * 12.7 - 1.27, s * 12.7 + 1.27, Z_PCB - 2.5, Z_PCB))
        m.append(box('Mock_PinTips' + tag, c, pin_x(1) - 0.32, pin_x(15) + 0.32, s * 12.7 - 0.32, s * 12.7 + 0.32, Z_PCB_TOP, Z_PCB_TOP + 2.5))
    for s, pins in ((1, (14, 15)), (-1, (6, 7, 8, 14))):
        for i in pins:
            m.append(box('Mock_Dupont' + tag, c, pin_x(i) - 1.27, pin_x(i) + 1.27, s * 12.7 - 1.27, s * 12.7 + 1.27,
                         Z_PCB - 2.5 - 14, Z_PCB - 2.5))
    mx, my = P['mic_x'], P['mic_y']
    z_mic = Z_BODY - 1.0                                   # busa 1 mm
    m.append(cyl('Mock_Mic' + tag, c, mic_d / 2, z_mic - 1.0, z_mic, mx, my, seg=64))
    m.append(box('Mock_MicDupont' + tag, c, mx - 3.81, mx + 3.81, my - 2.54, my + 2.54, z_mic - 1.0 - 2.5 - 14, z_mic - 1.0))
    return m


# ---------- cek ----------
def mesh_report(ob):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    nm = sum(1 for e in bm.edges if not e.is_manifold)
    vol = bm.calc_volume()
    bm.free()
    return dict(non_manifold=nm, volume_cm3=round(vol / 1000, 2), size=[round(v, 2) for v in ob.dimensions])


def bvh(ob, dz=0.0):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bm.transform(Matrix.Translation((0, 0, dz)) @ ob.matrix_world)
    t = BVHTree.FromBMesh(bm)
    bm.free()
    return t


def collisions(parts, mocks):
    """Tabrakan nyata saja: PCB & busa diangkat 0,02 mm supaya 'duduk di blok' tidak dihitung tabrakan."""
    out = []
    for p in parts:
        tp = bvh(p)
        for mk in mocks:
            dz = 0.02 if mk.name.startswith(('Mock_PCB', 'Mock_Foam')) else 0.0
            if tp.overlap(bvh(mk, dz)):
                out.append(f'{p.name} x {mk.name}')
    return out


def write_stl(ob, path, flip=False):
    M = ob.matrix_world.copy()
    if flip:
        M = Matrix.Translation((0, 0, P['H'])) @ Matrix.Rotation(math.pi, 4, 'X') @ M
    me = ob.data
    me.calc_loop_triangles()
    vs = [M @ v.co for v in me.vertices]
    with open(path, 'wb') as f:
        f.write(b'puck'.ljust(80, b' '))
        f.write(struct.pack('<I', len(me.loop_triangles)))
        for t in me.loop_triangles:
            a, b, cc = (vs[i] for i in t.vertices)
            n = (b - a).cross(cc - a).normalized()
            f.write(struct.pack('<12fH', *n, *a, *b, *cc, 0))


def material(name, rgba):
    mt = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mt.diffuse_color = rgba
    return mt


COLORS = {'PCB': (0.05, 0.05, 0.06, 1), 'Module': (0.75, 0.75, 0.78, 1), 'USBC': (0.8, 0.8, 0.82, 1),
          'Plug': (0.55, 0.55, 0.55, 1), 'Button': (0.2, 0.2, 0.2, 1), 'Header': (0.02, 0.02, 0.02, 1),
          'PinTips': (0.85, 0.7, 0.3, 1), 'Dupont': (0.1, 0.1, 0.1, 1), 'Mic': (0.1, 0.1, 0.15, 1),
          'MicDupont': (0.9, 0.75, 0.1, 1), 'Foam': (0.3, 0.5, 0.9, 1)}


# ---------- main ----------
def build():
    sc = bpy.context.scene
    sc.unit_settings.system = 'METRIC'
    sc.unit_settings.scale_length = 0.001
    sc.unit_settings.length_unit = 'MILLIMETERS'
    for name in ('Puck', 'Puck_Mockup', 'Puck_Check'):
        old = bpy.data.collections.get(name)
        if old:
            for o in list(old.objects):
                bpy.data.objects.remove(o)
            bpy.data.collections.remove(old)
    cp = bpy.data.collections.new('Puck')
    cm = bpy.data.collections.new('Puck_Mockup')
    ck = bpy.data.collections.new('Puck_Check')
    for col in (cp, cm, ck):
        sc.collection.children.link(col)

    body = build_body(cp)
    lid = build_lid(cp)
    white = material('Puck_White', (0.92, 0.92, 0.9, 1))
    for o in (body, lid):
        o.data.materials.append(white)

    # cek ukuran board & mic terkecil sampai terbesar yang dijual
    checks = {}
    for L, W, d in ((50.0, 26.0, 13.0), (51.0, 28.0, 14.0), (52.0, 28.5, 14.5), (52.5, 28.5, 15.0)):
        ms = build_mock(ck, L, W, d, tag=f'_{L}x{W}')
        checks[f'{L}x{W} mic{d}'] = collisions([body, lid], ms)
        for o in ms:
            bpy.data.objects.remove(o)
    bpy.data.collections.remove(ck)

    mocks = build_mock(cm, 51.8, 28.2, 14.0)               # tampilan di viewport
    for o in mocks:
        key = o.name.split('_')[1].split('.')[0]
        o.data.materials.append(material('Mock_' + key, COLORS.get(key, (1, 0, 0, 1))))

    lid_lift = bvh(body).overlap(bvh(lid, 0.02))
    os.makedirs(P['out'], exist_ok=True)
    write_stl(body, os.path.join(P['out'], 'puck-body.stl'))
    write_stl(lid, os.path.join(P['out'], 'puck-lid.stl'), flip=True)

    return dict(body=mesh_report(body), lid=mesh_report(lid), size_checks=checks,
                body_lid_overlap=bool(lid_lift), x_usb=round(X_USB, 2), x_ant_stop=round(X_ANT_MAX, 2))


RESULT = build()
print('PUCK_RESULT', RESULT)
