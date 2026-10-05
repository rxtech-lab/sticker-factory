// Safari runs this before opening the share extension. The result is delivered as a property list.
var PetPage = function () {};
PetPage.prototype = {
    mainRoot: function () {
        var candidates = document.querySelectorAll("article, [role=main], main");
        var best = null, length = 0;
        for (var i = 0; i < candidates.length; i++) {
            var size = (candidates[i].innerText || candidates[i].textContent || "").length;
            if (size > length) { best = candidates[i]; length = size; }
        }
        return length >= 200 ? best : document.body;
    },
    run: function (arguments) {
        var root = this.mainRoot();
        var clone = root ? root.cloneNode(true) : null;
        if (clone) {
            var junk = clone.querySelectorAll("script, style, noscript, template, iframe, form, nav, aside, footer, [aria-hidden=true], .advertisement, .comments");
            for (var i = 0; i < junk.length; i++) junk[i].remove();
            var links = clone.querySelectorAll("a[href], img[src]");
            var originals = root.querySelectorAll("a[href], img[src]");
            for (var j = 0; j < links.length; j++) {
                if (links[j].tagName === "A") links[j].setAttribute("href", originals[j].href);
                else links[j].setAttribute("src", originals[j].currentSrc || originals[j].src);
            }
        }
        var text = clone ? (clone.innerText || clone.textContent || "") : "";
        var html = clone ? clone.innerHTML : "";
        arguments.completionFunction({
            url: document.URL || "",
            title: document.title || "",
            content: text.trim().substring(0, 20000),
            html: html.length <= 40000 ? html : ""
        });
    },
    finalize: function (arguments) {}
};
var ExtensionPreprocessingJS = new PetPage();
