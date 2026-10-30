# frozen_string_literal: true
require "fileutils"

OUT = File.expand_path("../examples/fixtures/ocr_hello.png", __dir__)
FileUtils.mkdir_p(File.dirname(OUT))

JXA = <<~JS
  ObjC.import('Foundation');
  ObjC.import('AppKit');

  const text = 'HELLO RUBY';
  const width = 800;
  const height = 200;
  const fontSize = 96.0;

  const size = $.NSMakeSize(width, height);
  const image = $.NSImage.alloc.initWithSize(size);
  image.lockFocus;

  $.NSColor.whiteColor.setFill;
  $.NSBezierPath.fillRect($.NSMakeRect(0, 0, width, height));

  const font = $.NSFont.fontWithNameSize('Helvetica-Bold', fontSize);
  const attrKeys = ['NSFont', 'NSColor'];
  const attrVals = [font, $.NSColor.blackColor];
  const attrs = $.NSDictionary.dictionaryWithObjectsForKeys(attrVals, attrKeys);

  const nsText = $(text);
  const textSize = nsText.sizeWithAttributes(attrs);
  const x = (width - textSize.width) / 2;
  const y = (height - textSize.height) / 2;
  nsText.drawAtPointWithAttributes($.NSMakePoint(x, y), attrs);

  image.unlockFocus;

  const tiffData = image.TIFFRepresentation;
  const rep = $.NSBitmapImageRep.imageRepWithData(tiffData);
  const pngData = rep.representationUsingTypeProperties(
    $.NSBitmapImageFileTypePNG,
    $.NSDictionary.dictionary
  );

  const path = '#{OUT}';
  pngData.writeToFileAtomically(path, true);
  'wrote ' + path;
JS

require "open3"
out, err, status = Open3.capture3("osascript", "-l", "JavaScript", "-e", JXA)
unless status.success?
  abort "osascript JXA failed:\n#{err}"
end
puts out.strip
unless File.exist?(OUT)
  abort "expected output PNG not produced: #{OUT}"
end
puts "size=#{File.size(OUT)} bytes"
