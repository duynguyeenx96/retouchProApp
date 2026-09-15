import CoreGraphics
import Foundation
import RPCore
import Testing

@testable import RPEngine

/// Phase 6.2 "Đầu" — the geometry half: the hair trace, the handles it becomes,
/// and the properties the head field must have for any face.
///
/// Nothing here touches a GPU or a feature flag, so it runs anywhere and says
/// nothing about how fast or how pretty the group is. What it does say is that
/// the two pieces of new maths are right:
///
/// 1. **The trace** (``HairBoundary``) against an *independent* implementation —
///    `Research/bench/hair-boundary-reference.py`, NumPy, largest 4-connected
///    component by label propagation and the boundary as per-row/column
///    extremes. Different data structure, different traversal, no shared line.
///    See ``HairlineReference`` for why the comparison is extremes and not a
///    pixel set.
/// 2. **The handles** (``HeadReshape``) — which points move, by how much, in
///    which direction, and that every magnitude scales with the face.
@Suite("Phase 6.2 head reshape geometry")
struct HeadReshapeGeometryTests {

    // MARK: - 1. The trace against the NumPy reference

    @Test("The Swift trace and the NumPy reference agree on every synthetic shape")
    func traceMatchesTheReferenceOnSyntheticShapes() throws {
        // The reference JSON is committed, so its absence is a broken checkout
        // rather than a missing research artefact — this one does not skip.
        let document = try #require(
            HairlineReference.document,
            "Research/bench/p6-head-hairline-reference.json is missing; regenerate it with Research/bench/hair-boundary-reference.py")
        #expect(document.synthetic.count == 7)

        for shape in document.synthetic {
            let mask = HairlineReference.mask(shape)
            let outline = try #require(HairBoundary.trace(mask), "\(shape.name): no outline")

            #expect(outline.maskPixelCount == shape.mask_pixels, "\(shape.name) mask pixels")
            #expect(
                outline.componentPixelCount == shape.component_pixels,
                "\(shape.name) component pixels")

            // The trace starts at the component's topmost-then-leftmost pixel,
            // which is the smallest row-major index — the same pixel the
            // reference's label propagation converges every component onto.
            let start = try #require(shape.start_pixel)
            #expect(Int(floor(outline.contour[0].location.x)) == start[0], "\(shape.name) start x")
            #expect(Int(floor(outline.contour[0].location.y)) == start[1], "\(shape.name) start y")

            let extremes = RingExtremes.of(outline.contour)
            for row in try #require(shape.rows) {
                let (y, left, right) = (row[0], row[1], row[2])
                let traced = try #require(extremes.rows[y], "\(shape.name): row \(y) not traced")
                #expect(traced.0 == left, "\(shape.name) row \(y) leftmost")
                #expect(traced.1 == right, "\(shape.name) row \(y) rightmost")
            }
            for col in try #require(shape.cols) {
                let (x, top, bottom) = (col[0], col[1], col[2])
                let traced = try #require(extremes.cols[x], "\(shape.name): col \(x) not traced")
                #expect(traced.0 == top, "\(shape.name) col \(x) topmost")
                #expect(traced.1 == bottom, "\(shape.name) col \(x) bottommost")
            }
            // …and nothing traced is outside the component's own rows/columns,
            // which is the other half: the ring must not wander off the region.
            let bbox = try #require(shape.bbox)
            for point in outline.contour {
                let x = Int(floor(point.location.x))
                let y = Int(floor(point.location.y))
                #expect(x >= bbox[0] && x <= bbox[2], "\(shape.name): traced x \(x)")
                #expect(y >= bbox[1] && y <= bbox[3], "\(shape.name): traced y \(y)")
                #expect(
                    mask.values[y * mask.width + x] >= HairBoundary.coverageThreshold,
                    "\(shape.name): traced a pixel that is not in the mask")
            }
        }
    }

    @Test("The Swift trace and the NumPy reference agree on all 11 real a6300 hair masks")
    func traceMatchesTheReferenceOnRealFrames() throws {
        let document = try #require(HairlineReference.document)
        guard !document.real.isEmpty else {
            print("P6.2 head trace vs reference: SKIP (reference has no real frames)")
            return
        }
        let frames = HairMaskFixtures.a6300
        guard !frames.isEmpty else {
            print("P6.2 head trace vs reference: SKIP (a6300 parsing fixture absent)")
            return
        }

        var checked = 0
        for frame in frames {
            let name = (frame.image as NSString).deletingPathExtension + ".png"
            guard let entry = document.real.first(where: { $0.image == name }) else { continue }
            // Traced in *mask* pixels: the reference knows nothing about the
            // affine onto the photograph, and mixing the two would compare a
            // rotation against a set of integers.
            let raw = RenderMask(
                width: frame.mask.width, height: frame.mask.height, values: frame.mask.values,
                maskToImage: .identity)
            let outline = try #require(HairBoundary.trace(raw), "\(name): no outline")

            #expect(outline.maskPixelCount == entry.mask_pixels, "\(name) mask pixels")
            #expect(outline.componentPixelCount == entry.component_pixels, "\(name) component")

            let extremes = RingExtremes.of(outline.contour)
            var worstRow = 0
            for row in try #require(entry.rows) {
                let traced = try #require(extremes.rows[row[0]], "\(name): row \(row[0])")
                worstRow = max(worstRow, abs(traced.0 - row[1]), abs(traced.1 - row[2]))
            }
            var worstCol = 0
            for col in try #require(entry.cols) {
                let traced = try #require(extremes.cols[col[0]], "\(name): col \(col[0])")
                worstCol = max(worstCol, abs(traced.0 - col[1]), abs(traced.1 - col[2]))
            }
            #expect(worstRow == 0, "\(name): row extremes differ by \(worstRow) px")
            #expect(worstCol == 0, "\(name): column extremes differ by \(worstCol) px")
            checked += 1
        }
        print("P6.2 head trace vs NumPy reference: \(checked) real a6300 frames, exact")
        #expect(checked == 11)
    }

    @Test("A point on the crop edge is marked clipped and never becomes a handle")
    func clippedPointsAreDroppedFromTheHandles() throws {
        let document = try #require(HairlineReference.document)
        let bar = try #require(document.synthetic.first { $0.name == "clipped_bar" })
        let outline = try #require(HairBoundary.trace(HairlineReference.mask(bar)))

        // The reference says which edges the component touches; the trace must
        // mark exactly the points on those edges.
        #expect(outline.clippedCount > 0)
        for point in outline.contour {
            let x = Int(floor(point.location.x))
            let y = Int(floor(point.location.y))
            let onEdge = x == 0 || y == 0 || x == bar.size[0] - 1 || y == bar.size[1] - 1
            #expect(point.isClipped == onEdge, "clip flag at (\(x), \(y))")
        }

        // A resampled sample straddling a clipped segment is clipped too — the
        // deliberately pessimistic rule ``HairBoundary/Outline/resampled(count:)``
        // documents.
        let resampled = outline.resampled(count: 24)
        #expect(resampled.count == 24)
        #expect(resampled.contains { $0.isClipped })
        #expect(resampled.contains { !$0.isClipped })

        // And a head built on this silhouette uses only the unclipped part.
        let head = SyntheticHead.make(clipped: true)
        let silhouette = try #require(
            HeadReshape.silhouette(
                landmarks: head.face.landmarks, faceWidth: head.face.faceWidth,
                hair: head.face.masks[.hair]))
        #expect(silhouette.clippedCount > 0)
        #expect(silhouette.hair.count == silhouette.polygon.count - silhouette.clippedCount)
        let handles = HeadReshape.handles(
            landmarks: head.face.landmarks, faceWidth: head.face.faceWidth,
            hair: head.face.masks[.hair], face: FaceSliders(), head: HeadSliders(volume: 100))
        #expect(handles.count { $0.role == .hairBoundary } <= silhouette.hair.count)
    }

    @Test("Resampling keeps the ring closed, ordered and on the outline")
    func resamplingIsUniformAndOrdered() throws {
        let document = try #require(HairlineReference.document)
        let disc = try #require(document.synthetic.first { $0.name == "disc" })
        let outline = try #require(HairBoundary.trace(HairlineReference.mask(disc)))
        let full = outline.contour

        let resampled = outline.resampled(count: 32)
        #expect(resampled.count == 32)
        #expect(resampled[0].location == full[0].location)

        // Uniform arc length: every step is the same to within the polyline's own
        // vertex spacing (the samples are interpolated along segments, so an
        // exact equality is not available, but a 5 % spread is).
        var steps: [CGFloat] = []
        for i in 0..<resampled.count {
            let a = resampled[i].location
            let b = resampled[(i + 1) % resampled.count].location
            steps.append(hypot(b.x - a.x, b.y - a.y))
        }
        let mean = steps.reduce(0, +) / CGFloat(steps.count)
        for step in steps { #expect(abs(step - mean) < 0.05 * mean) }

        // Asking for more points than the ring has returns the ring, unchanged —
        // no interpolation, no duplicates.
        #expect(outline.resampled(count: full.count * 2).count == full.count)
        // A one-pixel component survives resampling without dividing by zero.
        let single = try #require(document.synthetic.first { $0.name == "single_pixel" })
        let dot = try #require(HairBoundary.trace(HairlineReference.mask(single)))
        #expect(dot.contour.count == 1)
        #expect(dot.resampled(count: 16).count == 1)
    }

    @Test("An empty or sub-threshold mask has no outline at all")
    func anEmptyMaskHasNoOutline() {
        let empty = RenderMask(
            width: 32, height: 32, values: [UInt8](repeating: 0, count: 1024),
            maskToImage: .identity)
        #expect(HairBoundary.trace(empty) == nil)

        // 127 is below the half-coverage isoline, 128 is on it.
        let faint = RenderMask(
            width: 32, height: 32, values: [UInt8](repeating: 127, count: 1024),
            maskToImage: .identity)
        #expect(HairBoundary.trace(faint) == nil)
        let solid = RenderMask(
            width: 32, height: 32, values: [UInt8](repeating: 128, count: 1024),
            maskToImage: .identity)
        #expect(HairBoundary.trace(solid) != nil)
    }

    @Test("The trace is in image pixels, through the mask's own affine")
    func theTraceIsInImagePixels() throws {
        let document = try #require(HairlineReference.document)
        let disc = try #require(document.synthetic.first { $0.name == "disc" })
        let base = HairlineReference.mask(disc)
        let scaled = RenderMask(
            width: base.width, height: base.height, values: base.values,
            maskToImage: CGAffineTransform(scaleX: 4, y: 4)
                .concatenating(CGAffineTransform(translationX: 100, y: 7)))
        let plain = try #require(HairBoundary.trace(base))
        let moved = try #require(HairBoundary.trace(scaled))
        #expect(plain.contour.count == moved.contour.count)
        for i in 0..<plain.contour.count {
            let p = plain.contour[i].location
            let q = moved.contour[i].location
            #expect(abs(q.x - (p.x * 4 + 100)) < 1e-9)
            #expect(abs(q.y - (p.y * 4 + 7)) < 1e-9)
        }
    }

    // MARK: - 2. The handles

    @Test("With no hair mask the head sliders do nothing at all")
    func noHairMaskMeansNoHeadHandles() {
        let face = SyntheticFaceMesh.renderInput(width: 200, centre: CGPoint(x: 192, y: 150))
        #expect(
            HeadReshape.silhouette(
                landmarks: face.landmarks, faceWidth: face.faceWidth, hair: nil) == nil)
        #expect(
            HeadReshape.handles(
                landmarks: face.landmarks, faceWidth: face.faceWidth, hair: nil,
                face: FaceSliders(), head: HeadSliders(size: 100, width: 100, volume: 100))
                .isEmpty)
        #expect(
            HeadReshape.controlPoints(
                faces: [face], face: FaceSliders(),
                head: HeadSliders(size: 100, width: 100, volume: 100),
                imageSize: CGSize(width: 384, height: 448)) == nil)

        // An empty hair mask is the same answer (a hat, a bald subject).
        var bald = face
        bald.masks[.hair] = RenderMask(
            width: 64, height: 64, values: [UInt8](repeating: 0, count: 64 * 64),
            maskToImage: .identity)
        #expect(
            HeadReshape.handles(
                landmarks: bald.landmarks, faceWidth: bald.faceWidth, hair: bald.masks[.hair],
                face: FaceSliders(), head: HeadSliders(size: 100)).isEmpty)
    }

    @Test("Head sliders at 0 reproduce the Mặt group's handles exactly")
    func zeroHeadSlidersAreTheFaceGroupExactly() throws {
        let head = SyntheticHead.make()
        let face = FaceSliders(slim: 40, chin: 30, eyeSize: 20, lipFullness: 50)
        let mine = HeadReshape.handles(
            landmarks: head.face.landmarks, faceWidth: head.face.faceWidth,
            hair: head.face.masks[.hair], face: face, head: HeadSliders())
        let theirs = FaceReshape.handles(
            landmarks: head.face.landmarks, faceWidth: head.face.faceWidth, sliders: face)
        #expect(mine.count == theirs.count)
        for i in 0..<theirs.count {
            #expect(mine[i].index == theirs[i].index)
            #expect(mine[i].source == theirs[i].source)
            #expect(mine[i].destination == theirs[i].destination)
            #expect(mine[i].role == .faceMesh)
        }
    }

    @Test("Each head slider moves the region it names, in the direction it names")
    func eachSliderMovesItsOwnRegion() throws {
        let head = SyntheticHead.make()
        let frame = FaceMeshFrame(
            landmarks: head.face.landmarks, faceWidth: head.face.faceWidth)!

        func built(_ sliders: HeadSliders) -> [HeadReshape.Handle] {
            HeadReshape.handles(
                landmarks: head.face.landmarks, faceWidth: head.face.faceWidth,
                hair: head.face.masks[.hair], face: FaceSliders(), head: sliders)
        }

        // --- size: everything moves toward the pivot, the crown most.
        let size = built(HeadSliders(size: 100))
        let pivot = HeadReshape.axisPoint(frame, t: HeadReshape.pivotT)
        for handle in size where handle.displacement > 0 {
            let before = hypot(handle.source.x - pivot.x, handle.source.y - pivot.y)
            let after = hypot(
                handle.destination.x - pivot.x, handle.destination.y - pivot.y)
            #expect(after < before, "size moved a handle away from the pivot")
        }
        let crown = try #require(size.first { $0.index == FaceMesh.foreheadTop })
        let chin = try #require(size.first { $0.index == FaceMesh.chin })
        #expect(crown.displacement > chin.displacement)
        // Every role takes part — the hair scales with the head.
        #expect(size.contains { $0.role == .hairBoundary && $0.displacement > 0 })

        // --- width: lateral only, above the eye line only.
        let width = built(HeadSliders(width: 100))
        for handle in width {
            let t = frame.t(handle.source)
            let u = frame.u(handle.source)
            if t >= frame.tCheekLine {
                #expect(handle.displacement < 1e-9, "width moved a point below the cheek line")
            }
            guard handle.displacement > 1e-9 else { continue }
            let movedU = frame.u(handle.destination)
            #expect(abs(movedU) < abs(u), "width pushed a point away from the midline")
            // Along the axis: nothing.
            let along =
                (handle.destination.x - handle.source.x) * frame.down.dx
                + (handle.destination.y - handle.source.y) * frame.down.dy
            #expect(abs(along) < 1e-9)
        }

        // --- volume: the silhouette moves, the face is an identity handle.
        let volume = built(HeadSliders(volume: 100))
        for handle in volume where handle.role == .faceMesh {
            #expect(handle.displacement == 0, "volume moved a face landmark")
        }
        let crownCentre = HeadReshape.axisPoint(frame, t: HeadReshape.crownCentreT)
        var movedSilhouette = 0
        for handle in volume where handle.role == .hairBoundary && handle.displacement > 1e-9 {
            let before = hypot(
                handle.source.x - crownCentre.x, handle.source.y - crownCentre.y)
            let after = hypot(
                handle.destination.x - crownCentre.x, handle.destination.y - crownCentre.y)
            #expect(after > before, "volume pulled the silhouette inward")
            #expect(frame.t(handle.source) < frame.tEyeLine)
            movedSilhouette += 1
        }
        #expect(movedSilhouette > 0)
        // The ring takes exactly half of it — that is what the ring is for.
        for handle in volume where handle.role == .expandedRing {
            #expect(handle.displacement >= 0)
        }
    }

    @Test("The expanded ring sits between the face oval and the hairline")
    func theExpandedRingIsAnchoredToTheHairline() throws {
        let head = SyntheticHead.make()
        let silhouette = try #require(
            HeadReshape.silhouette(
                landmarks: head.face.landmarks, faceWidth: head.face.faceWidth,
                hair: head.face.masks[.hair]))
        #expect(!silhouette.ring.isEmpty)

        let frame = FaceMeshFrame(
            landmarks: head.face.landmarks, faceWidth: head.face.faceWidth)!
        let centre = HeadReshape.axisPoint(frame, t: HeadReshape.crownCentreT)

        // Rebuilt from the same ingredients the production code used: for every
        // oval landmark above the cheek line, the ray from the head centre
        // through it, the first hairline crossing beyond it, and the point
        // `ringFraction` of the way there. "Expanded outward, proportionally,
        // anchored to the hair boundary" as a check rather than as a sentence.
        var expected: [CGPoint] = []
        for index in FaceMesh.faceOval {
            let point = head.face.landmarks[index]
            guard frame.t(point) <= frame.tCheekLine,
                let hit = HeadReshape.hairlineHit(
                    from: centre, through: point, polygon: silhouette.polygon)
            else { continue }
            let span = hypot(hit.x - point.x, hit.y - point.y)
            guard span > 0, span <= HeadReshape.maxRingSpanFraction * frame.width else {
                continue
            }
            // Strictly between the oval and the hairline, on the same ray.
            let ring = CGPoint(
                x: point.x + (hit.x - point.x) * HeadReshape.ringFraction,
                y: point.y + (hit.y - point.y) * HeadReshape.ringFraction)
            let toOval = hypot(point.x - centre.x, point.y - centre.y)
            let toRing = hypot(ring.x - centre.x, ring.y - centre.y)
            let toHair = hypot(hit.x - centre.x, hit.y - centre.y)
            #expect(toOval < toRing && toRing < toHair)
            expected.append(ring)
        }
        #expect(silhouette.ring.count == expected.count)
        for i in 0..<expected.count {
            #expect(abs(silhouette.ring[i].x - expected[i].x) < 1e-9)
            #expect(abs(silhouette.ring[i].y - expected[i].y) < 1e-9)
        }
        // The synthetic bob surrounds the whole upper oval, so every landmark
        // above the cheek line should have produced one.
        let above = FaceMesh.faceOval.count {
            frame.t(head.face.landmarks[$0]) <= frame.tCheekLine
        }
        print("P6.2 head ring: \(silhouette.ring.count) of \(above) oval points above the cheek line")
        #expect(silhouette.ring.count >= above - 2)
    }

    @Test("Displacements scale exactly with the face")
    func headDisplacementsScaleWithTheFace() throws {
        let sliders = HeadSliders(size: 60, width: 70, volume: 80)
        let small = SyntheticHead.make(
            faceWidth: 100, centre: CGPoint(x: 96, y: 75), width: 192, height: 224,
            maskScale: 1)
        let large = SyntheticHead.make(
            faceWidth: 300, centre: CGPoint(x: 288, y: 225), width: 576, height: 672,
            maskScale: 1)

        func handles(_ head: SyntheticHead.Head) -> [HeadReshape.Handle] {
            HeadReshape.handles(
                landmarks: head.face.landmarks, faceWidth: head.face.faceWidth,
                hair: head.face.masks[.hair], face: FaceSliders(), head: sliders)
        }
        let a = handles(small).filter { $0.index != nil }
        let b = handles(large).filter { $0.index != nil }
        #expect(a.count == b.count)
        #expect(!a.isEmpty)

        let scale: CGFloat = 3
        var worst: CGFloat = 0
        for i in 0..<a.count {
            #expect(a[i].index == b[i].index)
            let da = CGVector(
                dx: a[i].destination.x - a[i].source.x, dy: a[i].destination.y - a[i].source.y)
            let db = CGVector(
                dx: b[i].destination.x - b[i].source.x, dy: b[i].destination.y - b[i].source.y)
            worst = max(worst, abs(db.dx - da.dx * scale), abs(db.dy - da.dy * scale))
        }
        print("P6.2 head scale invariance: worst |Δ(3×) − 3·Δ| = \(worst) px")
        // The mask is rasterised at each size, so the silhouette is not identical
        // at 1× and 3× — but the *mesh* handles have no mask in them at all and
        // must scale exactly. 1e-9 × 300 px is the float noise floor.
        #expect(worst < 1e-6)
    }

    @Test("The head field follows the head's roll")
    func theHeadFieldFollowsTheRoll() throws {
        let sliders = HeadSliders(size: 50, width: 50, volume: 50)
        let upright = SyntheticHead.make(maskScale: 1)
        let rolled = SyntheticHead.make(rotation: 0.4, maskScale: 1)

        func meshDisplacements(_ head: SyntheticHead.Head) -> [Int: CGVector] {
            var out: [Int: CGVector] = [:]
            for handle in HeadReshape.handles(
                landmarks: head.face.landmarks, faceWidth: head.face.faceWidth,
                hair: head.face.masks[.hair], face: FaceSliders(), head: sliders)
            {
                guard let index = handle.index else { continue }
                out[index] = CGVector(
                    dx: handle.destination.x - handle.source.x,
                    dy: handle.destination.y - handle.source.y)
            }
            return out
        }
        let a = meshDisplacements(upright)
        let b = meshDisplacements(rolled)
        #expect(a.count == b.count)

        // Rotating the whole head must rotate every displacement with it: the
        // magnitudes are identical and the angles differ by exactly the roll.
        var worst: CGFloat = 0
        for (index, va) in a {
            let vb = try #require(b[index])
            let rotated = CGVector(
                dx: cos(0.4) * va.dx - sin(0.4) * va.dy,
                dy: sin(0.4) * va.dx + cos(0.4) * va.dy)
            worst = max(worst, abs(vb.dx - rotated.dx), abs(vb.dy - rotated.dy))
        }
        print("P6.2 head roll invariance: worst |Δ(rolled) − R·Δ| = \(worst) px")
        #expect(worst < 1e-6 * 200)
    }

    @Test("Two handles never share a position")
    func handlesAreNeverCoincident() throws {
        let head = SyntheticHead.make()
        let built = try #require(
            HeadReshape.controlPoints(
                faces: [head.face], face: FaceReshapeTests.allSliders,
                head: HeadSliders(size: 80, width: 80, volume: 80),
                imageSize: CGSize(width: CGFloat(head.width), height: CGFloat(head.height))))
        let minimum = HeadReshape.minSeparationFraction * head.face.faceWidth
        // Two handles at the same place with different destinations is an
        // ill-conditioned solve, so the closest pair is measured rather than
        // asserted pair by pair (that would be ~40 000 expectations).
        var closest = CGFloat.greatestFiniteMagnitude
        for i in 0..<built.handles.count {
            for j in (i + 1)..<built.handles.count {
                let a = built.handles[i].source
                let b = built.handles[j].source
                closest = min(closest, hypot(a.x - b.x, a.y - b.y))
            }
        }
        #expect(closest > 0, "two handles share a position")

        // Ring and hair points additionally keep their distance from the mesh.
        let mesh = built.handles.filter { $0.role == .faceMesh }.map(\.source)
        var closestToMesh = CGFloat.greatestFiniteMagnitude
        for handle in built.handles where handle.role != .faceMesh {
            for point in mesh {
                closestToMesh = min(
                    closestToMesh, hypot(handle.source.x - point.x, handle.source.y - point.y))
            }
        }
        #expect(
            closestToMesh >= minimum,
            "a head handle sits \(closestToMesh) px from a mesh handle (minimum \(minimum))")
        #expect(built.crowdedPointCount >= 0)
        print(
            "P6.2 head handles: \(built.faceMeshHandleCount) mesh + "
                + "\(built.ringHandleCount) ring + \(built.hairHandleCount) hair "
                + "(+\(built.borderAnchorCount) border), \(built.crowdedPointCount) crowded, "
                + "\(built.clippedPointCount) clipped")
    }

    @Test("Mặt and Đầu compose: one handle per landmark, both contributions in it")
    func theTwoGroupsComposeWithoutFighting() throws {
        let head = SyntheticHead.make()
        let face = FaceSliders(slim: 80, chin: 60)
        let sliders = HeadSliders(size: 70)

        let combined = HeadReshape.handles(
            landmarks: head.face.landmarks, faceWidth: head.face.faceWidth,
            hair: head.face.masks[.hair], face: face, head: sliders)
        let faceOnly = FaceReshape.handles(
            landmarks: head.face.landmarks, faceWidth: head.face.faceWidth, sliders: face)
        let field = try #require(
            HeadReshape.field(
                landmarks: head.face.landmarks, faceWidth: head.face.faceWidth,
                sliders: sliders))

        // One handle per mesh index, and its destination is exactly
        // "where Mặt put it, plus the head field at the undeformed point".
        var indices: Set<Int> = []
        for handle in combined where handle.role == .faceMesh {
            let index = try #require(handle.index)
            #expect(indices.insert(index).inserted, "index \(index) appears twice")
            let reshaped =
                faceOnly.first { $0.index == index }?.destination ?? handle.source
            let delta = field.displacement(at: handle.source, silhouetteWeight: 0)
            #expect(abs(handle.destination.x - (reshaped.x + delta.dx)) < 1e-9)
            #expect(abs(handle.destination.y - (reshaped.y + delta.dy)) < 1e-9)
        }
        // Every landmark the Mặt group moved is present in the combined set.
        for handle in faceOnly { #expect(indices.contains(handle.index)) }
    }

    // MARK: - Real data

    @Test("The real hair mask lines up with the real mesh")
    func theRealHairMaskLinesUpWithTheRealMesh() throws {
        let frames = HairMaskFixtures.a6300
        guard !frames.isEmpty else {
            print("P6.2 head alignment: SKIP (a6300 parsing fixture absent)")
            return
        }

        var better = 0
        var meanChosen = 0.0
        var meanFlipped = 0.0
        for frame in frames {
            let chosen = HeadAlignment.faceIoU(frame, flipRoll: false)
            let flipped = HeadAlignment.faceIoU(frame, flipRoll: true)
            if chosen > flipped { better += 1 }
            meanChosen += chosen
            meanFlipped += flipped
        }
        meanChosen /= Double(frames.count)
        meanFlipped /= Double(frames.count)
        print(
            "P6.2 head alignment: face-oval ∩ parser's facial classes, "
                + "IoU \(meanChosen) with the chosen derotation vs \(meanFlipped) with the "
                + "sign flipped; the chosen one wins on \(better)/\(frames.count) frames")
        // The fixture affine is derived, not guessed, but the *sign* of the
        // derotation is the one free bit in it — so it is measured here rather
        // than asserted in a comment.
        #expect(better == frames.count)
        #expect(meanChosen > meanFlipped)

        // And the traced silhouette must actually surround the face: the crown of
        // the head is above the forehead landmark, on the face's own axis.
        var surrounded = 0
        for frame in frames {
            let input = HairMaskFixtures.renderInput(frame)
            guard
                let silhouette = HeadReshape.silhouette(
                    landmarks: input.landmarks, faceWidth: input.faceWidth,
                    hair: input.masks[.hair]),
                let mesh = FaceMeshFrame(
                    landmarks: input.landmarks, faceWidth: input.faceWidth)
            else { continue }
            // Is any unclipped silhouette point above the forehead landmark?
            if silhouette.hair.contains(where: { mesh.t($0) < 0 }) { surrounded += 1 }
        }
        print("P6.2 head silhouette above the forehead landmark on \(surrounded)/\(frames.count)")
        #expect(surrounded >= 8)
    }
}

/// The alignment measurement the real-data fixture's affine rests on, kept out of
/// the test body so the bench can file the same numbers.
enum HeadAlignment {
    /// IoU between the face-oval polygon (from the mesh, mapped into the parsing
    /// mask's pixels) and the parser's own facial classes.
    ///
    /// Not a claim about the parser or about the mesh: both are already measured
    /// (ADR-0006, ADR-0008). It is a claim about the *transform between them*,
    /// and it is the only thing that distinguishes the two possible signs of the
    /// spike's derotation.
    static let facialClasses: Set<UInt8> = [1, 2, 3, 4, 5, 10, 11, 12, 13]

    static func faceIoU(_ frame: HairMaskFixtures.Frame, flipRoll: Bool) -> Double {
        let side = frame.labelSide
        let imageToMask = frame.maskToImage(rollSign: flipRoll ? 1 : -1).inverted()

        // The oval polygon in mask pixels. Sampled every second pixel in both
        // axes: this is a ratio over ~60 000 samples either way, and the full
        // 512² grid costs 30 s across the eleven frames for the same answer to
        // three decimals.
        let polygon = FaceMesh.faceOval.map { frame.mesh.landmarks[$0].applying(imageToMask) }
        var inside = 0
        var union = 0
        for y in stride(from: 0, to: side, by: 2) {
            for x in stride(from: 0, to: side, by: 2) {
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let inPolygon = contains(polygon, point)
                let inMask = facialClasses.contains(frame.labels[y * side + x])
                if inPolygon && inMask { inside += 1 }
                if inPolygon || inMask { union += 1 }
            }
        }
        return union > 0 ? Double(inside) / Double(union) : 0
    }

    /// Even-odd point in polygon.
    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
                point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
