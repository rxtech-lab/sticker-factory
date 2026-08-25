import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import AnimatedView

@MainActor
struct SVGFlattenerTests {
    @Test func flattensEveryStrokeIntoItsOwnSubpath() throws {
        let parsed = try #require(SVGFlattener.parse(markup: AnimatedPreviewSVG.strokeFace))
        // A circle plus three paths: the stagger feature depends on each staying addressable.
        #expect(parsed.drawing.subpathCount == 4)
        #expect(parsed.drawing.passthroughCount == 0)
        #expect(parsed.drawing.viewBox == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func subpathIDsAreSequentialInPaintOrder() throws {
        let parsed = try #require(SVGFlattener.parse(markup: AnimatedPreviewSVG.gradientBadge))
        #expect(parsed.drawing.subpaths.map(\.id) == Array(0..<parsed.drawing.subpathCount))
    }

    @Test func strokeOnlyMarkupProducesStrokesAndNoFills() throws {
        let parsed = try #require(SVGFlattener.parse(markup: AnimatedPreviewSVG.strokeCheck))
        let subpath = try #require(parsed.drawing.subpaths.first)
        #expect(subpath.stroke != nil)
        #expect(subpath.fill == nil)
        #expect(subpath.stroke?.cap == .round)
        #expect(subpath.stroke?.join == .round)
    }

    @Test func resolvesDefsGradients() throws {
        let parsed = try #require(SVGFlattener.parse(markup: AnimatedPreviewSVG.gradientBadge))
        let fills = parsed.drawing.subpaths.compactMap(\.fill)

        let linear = fills.first { if case .linearGradient = $0 { true } else { false } }
        let radial = fills.first { if case .radialGradient = $0 { true } else { false } }
        #expect(linear != nil, "url(#sky) should resolve to a linear gradient")
        #expect(radial != nil, "url(#glow) should resolve to a radial gradient")

        if case .linearGradient(let stops, _, _) = linear {
            #expect(stops.count == 2)
            #expect(stops.first?.color.hasPrefix("#7C5CFF") == true)
        }
    }

    @Test func appliesGroupTransformsToGeometry() throws {
        let untransformed = """
        <svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
          <rect x="0" y="0" width="10" height="10" fill="#000000"/>
        </svg>
        """
        let transformed = """
        <svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
          <g transform="translate(40 20)">
            <rect x="0" y="0" width="10" height="10" fill="#000000"/>
          </g>
        </svg>
        """
        let plain = try #require(SVGFlattener.parse(markup: untransformed)?.drawing.subpaths.first)
        let moved = try #require(SVGFlattener.parse(markup: transformed)?.drawing.subpaths.first)
        #expect(abs(plain.path.boundingRect.minX) < 0.001)
        #expect(abs(moved.path.boundingRect.minX - 40) < 0.001)
        #expect(abs(moved.path.boundingRect.minY - 20) < 0.001)
    }

    @Test func nestedGroupTransformsCompose() throws {
        let markup = """
        <svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
          <g transform="translate(10 0)">
            <g transform="translate(5 3)">
              <rect x="0" y="0" width="4" height="4" fill="#000000"/>
            </g>
          </g>
        </svg>
        """
        let subpath = try #require(SVGFlattener.parse(markup: markup)?.drawing.subpaths.first)
        #expect(abs(subpath.path.boundingRect.minX - 15) < 0.001)
        #expect(abs(subpath.path.boundingRect.minY - 3) < 0.001)
    }

    @Test func textBecomesAPassthroughRatherThanBeingDropped() throws {
        let parsed = try #require(SVGFlattener.parse(markup: AnimatedPreviewSVG.textBadge))
        #expect(parsed.drawing.passthroughCount == 1)
        #expect(parsed.passthroughNodes.count == 1)
        // The rect and the circle still flatten; only the <text> falls through.
        #expect(parsed.drawing.subpathCount == 2)
        // And it keeps its place in paint order, after the shapes it is drawn on top of.
        if case .passthrough = parsed.drawing.elements.last {} else {
            Issue.record("The text node should be last in paint order")
        }
    }

    @Test func rebuildsEveryPrimitiveShape() throws {
        let markup = """
        <svg viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg" fill="#000000">
          <rect x="0" y="0" width="20" height="10"/>
          <rect x="0" y="0" width="20" height="10" rx="4"/>
          <circle cx="50" cy="50" r="12"/>
          <ellipse cx="90" cy="50" rx="20" ry="8"/>
          <line x1="0" y1="100" x2="40" y2="140" stroke="#000000" stroke-width="2"/>
          <polyline points="0,150 20,170 40,150" stroke="#000000" stroke-width="2"/>
          <polygon points="60,150 80,170 100,150"/>
          <path d="M120 150 L160 150 L140 180 Z"/>
        </svg>
        """
        let parsed = try #require(SVGFlattener.parse(markup: markup))
        #expect(parsed.drawing.subpathCount == 8)
        #expect(parsed.drawing.passthroughCount == 0)
        for subpath in parsed.drawing.subpaths {
            #expect(!subpath.path.isEmpty, "Subpath \(subpath.id) flattened to nothing")
        }
    }

    @Test func fallsBackToArtworkBoundsWhenThereIsNoViewBox() throws {
        let markup = """
        <svg xmlns="http://www.w3.org/2000/svg">
          <rect x="10" y="20" width="30" height="40" fill="#000000"/>
        </svg>
        """
        let parsed = try #require(SVGFlattener.parse(markup: markup))
        #expect(parsed.drawing.viewBox.width > 0)
        #expect(parsed.drawing.viewBox.height > 0)
    }

    @Test func rejectsUnparseableMarkup() {
        #expect(SVGFlattener.parse(markup: "not an svg at all") == nil)
    }

    // MARK: - Bare path data

    @Test func parsesBarePathData() throws {
        let path = try #require(SVGFlattener.path(fromPathData: AnimatedPreviewSVG.boltPathData))
        #expect(!path.isEmpty)
        let bounds = path.boundingRect
        #expect(bounds.width > 0)
        #expect(bounds.height > 0)
    }

    @Test func curvedPathDataSurvivesRoundTrip() throws {
        let path = try #require(SVGFlattener.path(fromPathData: AnimatedPreviewSVG.signaturePathData))
        #expect(!path.isEmpty)
        #expect(path.boundingRect.width > 100)
    }

    @Test func rejectsEmptyPathData() {
        #expect(SVGFlattener.path(fromPathData: "") == nil)
    }

    /// `AnimatedShapeKind.path` must land in the layer box regardless of the coordinate space the
    /// author wrote it in — otherwise a path authored at 0–400 would render mostly off-canvas.
    @Test func customPathsAreRefittedIntoTheLayerBox() throws {
        let path = try #require(SVGFlattener.path(fromPathData: AnimatedPreviewSVG.boltPathData))
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let fitted = AnimatedShape.fitted(path, in: box)
        let bounds = fitted.boundingRect
        #expect(bounds.minX >= -0.001)
        #expect(bounds.minY >= -0.001)
        #expect(bounds.maxX <= 100.001)
        #expect(bounds.maxY <= 100.001)
        // Fitted, not stretched: one axis fills the box exactly.
        #expect(abs(bounds.width - 100) < 0.001 || abs(bounds.height - 100) < 0.001)
    }

    // MARK: - Cache

    @Test func cacheReturnsTheSameParseForTheSameMarkup() {
        let cache = SVGCache(capacity: 4)
        let source = AnimatedSVGSource.inline(markup: AnimatedPreviewSVG.strokeCheck)
        let first = cache.drawing(for: source, assets: EmptyAnimatedAssets())
        let second = cache.drawing(for: source, assets: EmptyAnimatedAssets())
        #expect(first == second)
        #expect(first != nil)
    }

    @Test func cacheResolvesAssetBackedMarkup() {
        let cache = SVGCache(capacity: 4)
        let assets = AnimatedAssetDictionary(svgMarkup: ["icon": AnimatedPreviewSVG.strokeCheck])
        #expect(cache.drawing(for: .asset(assetId: "icon"), assets: assets)?.subpathCount == 1)
        #expect(cache.drawing(for: .asset(assetId: "missing"), assets: assets) == nil)
    }
}
