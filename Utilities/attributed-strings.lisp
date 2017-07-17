;; attributed-strings.lisp

#|
The MIT license.

Copyright (c) 2011 Paul L. Krueger

Permission is hereby granted, free of charge, to any person obtaining a copy of this software 
and associated documentation files (the "Software"), to deal in the Software without restriction, 
including without limitation the rights to use, copy, modify, merge, publish, distribute, 
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is 
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial 
portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT 
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, 
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

|#
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :coerce-obj)
  (require :iu-classes))

(in-package :iu)

#| 

Lisp doesn't have anything like a Cocoa NSAttributedString. Our choices would be to just use the
Objective-C object or create a lisp class that can live in both worlds. Here we do the latter.
We can't make it a formal subclass of NSMutableAttributedString, because even though you can #/alloc and
#/init that class, it is, nevertheless a mostly abstract base class. If you inherit from it, most of its
critical methods are not implemented. So we create a normal Lisp class that encapsulates an instance of 
NSMutableAttributedString and make sure that other functions know how to extract that string when converting
this object to an NSObject form.

We also make this class inherit from fundamental-character-output-stream and provide methods that let people
use it as an output stream. To provide attributes for text that is sent to that stream we provide an accessor
method (format-attributes) that lets the attributes be set in advance. If no attributes are explicitly set, 
then the set in force for the last character of the existing string is used. The value of the format-attributes
slot is NOT the default for characters appended via an append-string call. For that, either the attributes must
be explicitly provided or the set in force for the last character of the current string is used. 

See detailed information about various parameter values that can be used at the bottom of this file.

|#

(defun all-font-names ()
  ;; convenience function that returns a list of all font names. When specifying a font attribute for
  ;; an attributed string it is CRITICAL that a valid font name be used. You can create an NSFont object
  ;; with an invalid name without complaint, but using it may cause strange Objective-C runtime exceptions.
  (let ((fm (#/sharedFontManager ns:ns-font-manager)))
    (ns-to-lisp-list (#/availableFonts fm))))

(defun print-all-font-names ()
  (format t "~{~%~a~}" (sort (all-font-names) #'string<)))

#|
(defclass attributed-string (fundamental-character-output-stream)
  ((att-ns-str :accessor att-ns-str)
   (ns-mut-str :accessor ns-mut-str)
   (as-view :accessor as-view
            :initarg :view)
   (format-attributes :accessor format-attributes
                      :initform nil))
  (:default-initargs
      :view nil))
|#

(defmethod initialize-instance :after ((self attributed-string)
                                       &key
                                       (str "")
                                       (attr nil)
                                       (copy nil)
                                       &allow-other-keys)
  (ccl:terminate-when-unreachable self)
  ;; if non-nil, attr key should be an assoc list with attributes and values for the string
  (let ((attr-dict (if (consp attr)
                       (lisp-to-ns-dict attr)
                       (%null-ptr))))
    (setf (att-ns-str self) 
          (typecase str
            (ns:ns-attributed-string
             ;; initialize with the given ns-object
             ;; note that if :copy is nil (default) this shares the specifed attributed string
             ;; note that :attr key is ignored in this case
             (if copy
                 (make-instance ns:ns-mutable-attributed-string
                   :with-attributed-string str)))
            (string
             ;; initialize by creating an NSMutableAttributedString
             (make-instance ns:ns-mutable-attributed-string
               :with-string (lisp-to-temp-nsstring str)
               :attributes attr-dict))
            (ns:ns-string
             ;; initialize by creating an NSMutableAttributedString from the ns-string
             (make-instance ns:ns-mutable-attributed-string
               :with-string str
               :attributes attr-dict))
            (attributed-string
             ;; initialize by using the att-ns-str of the str
             ;; note that if :copy is nil (default) this shares the specifed attributed string
             ;; note that :attr key is ignored in this case
              (if copy
                  (make-instance ns:ns-mutable-attributed-string
                    :with-attributed-string (att-ns-str str))
                (#/retain (att-ns-str str)))))))
  (setf (ns-mut-str self) (#/retain (#/mutableString (att-ns-str self)))))

(defmethod ccl:terminate ((self attributed-string))
  (when (slot-boundp self 'att-ns-str)
    (#/release (att-ns-str self)))
  (when (slot-boundp self 'ns-mut-str)
    (#/release (ns-mut-str self))))

(defmethod add-attribute ((self attributed-string) attr attr-val &key (start 0) (length nil))
  (with-slots (att-ns-str) self
    (ns:with-ns-range (r start (or length (#/length att-ns-str)))
      (#/addAttribute:value:range: att-ns-str
                                   (lisp-to-ns-object attr)
                                   (lisp-to-ns-object attr-val)
                                   r))))

(defmethod add-attributes ((self attributed-string) attrs &key (start 0) (length nil))
  (with-slots (att-ns-str) self
    (ns:with-ns-range (r start (or length (#/length att-ns-str)))
      (#/addAttributes:range: att-ns-str (lisp-to-ns-dict attrs) r))))

(defmethod append-string ((self attributed-string) (str string) &key (attrs nil))
  (if attrs
    (let ((as (#/initWithString:attributes: (#/alloc ns::ns-attributed-string)
                                            (lisp-to-temp-nsstring str)
                                            (lisp-to-ns-dict attrs))))
      (#/appendAttributedString: (att-ns-str self) as)
      (#/release as))
    (#/appendString: (ns-mut-str self) (lisp-to-temp-nsstring str))))

(defmethod apply-font-traits ((self attributed-string) trait-mask &key (start 0) (length nil))
  ;; see font-trace values at end of this file
  (with-slots (att-ns-str) self
    (ns:with-ns-range (r start (or length (- (#/length att-ns-str) start)))
      (#/applyFontTraits:range: att-ns-str trait-mask r))))

(defmethod attribute-at-index ((self attributed-string) attr index)
  (ns-to-lisp-object (#/attribute:atIndex:effectiveRange: (att-ns-str self) 
                                                          (lisp-to-ns-object attr)
                                                          index
                                                          (%null-ptr))))

(defmethod attributed-string-equal ((self attributed-string) (other-str attributed-string))
  (#/isEqualToAttributedString: (att-ns-str self) (att-ns-str other-str)))

(defmethod attributed-string-length ((self attributed-string))
  (#/length (att-ns-str self)))

(defmethod attributed-substring ((self attributed-string) &key (start 0) (length nil))
  (with-slots (att-ns-str) self
    (ns:with-ns-range (r start (or length (- (#/length att-ns-str) start)))
      (make-instance 'attributed-string
        :str (#/attributedSubstringFromRange: att-ns-str r)))))

(defmethod attributes-at-index ((self attributed-string) index)
  (ns-to-lisp-assoc (#/attributesAtIndex:effectiveRange: (att-ns-str self) index (%null-ptr))))

(defmethod insert-attributed-string-at-index ((self attributed-string) (insert-str attributed-string) index)
  (#/insertAttributedString:atIndex: (att-ns-str self) (att-ns-str insert-str) index)
  self)

(defmethod lisp-str ((self attributed-string))
  (ns-to-lisp-string (#/string (att-ns-str self))))

(defmethod print-object ((self attributed-string) strm)
  (print-unreadable-object (self strm :type t :identity t)))

(defmethod remove-attribute ((self attributed-string) attr &key (start 0) (length nil))
  ;; remove the specified attribute from characters in the indicated range
  (with-slots (att-ns-str) self
    (ns:with-ns-range (r start (or length (- (#/length att-ns-str) start)))
      (#/removeAttribute:range: (att-ns-str self) (lisp-to-ns-object attr) r))))

(defmethod replace-chars-in-range ((self attributed-string) (insert-str attributed-string) &key (start 0) (length nil))
  ;; replace the characters in the indicated range
  (ns:with-ns-range (r start (or length (- (#/length (att-ns-str self)) start)))
    (#/replaceCharactersInRange:withAttributedString: (att-ns-str self) r (att-ns-str insert-str))))

(defmethod replace-chars-in-range ((self attributed-string) (insert-str string) &key (start 0) (length nil))
  ;; replace the characters in the indicated range; attributes of inserted string come from first character replaced
  (ns:with-ns-range (r start (or length (- (#/length (att-ns-str self)) start)))
    (#/replaceCharactersInRange:withString: (att-ns-str self) r (lisp-to-temp-nsstring insert-str))))

(defmethod set-attributed-string ((self attributed-string) (from-str attributed-string))
  (#/setAttributedString: (att-ns-str self) (att-ns-str from-str)))

(defmethod set-attributes ((self attributed-string) attrs &key (start 0) (length nil))
  (with-slots (att-ns-str) self
    (ns:with-ns-range (r start (or length (- (#/length att-ns-str) start)))
      (#/setAttributes:range: att-ns-str (lisp-to-ns-dict attrs) r))))

(defmethod subscript-range ((self attributed-string) &key (start 0) (length nil))
  ;; decrements value of superscript attribute by 1 over the specified range
  (with-slots (att-ns-str) self
    (ns:with-ns-range (r start (or length (- (#/length att-ns-str) start)))
      (#/subscriptRange: att-ns-str r))))

(defmethod superscript-range ((self attributed-string) &key (start 0) (length nil))
  ;; increments value of superscript attribute by 1 over the specified range
  (with-slots (att-ns-str) self
    (ns:with-ns-range (r start (or length (- (#/length att-ns-str) start)))
      (#/superscriptRange: att-ns-str r))))

(defmethod unscript-range ((self attributed-string) &key (start 0) (length nil))
  ;; removes superscript attribute from the specified range
  (with-slots (att-ns-str) self
    (ns:with-ns-range (r start (or length (- (#/length att-ns-str) start)))
      (#/unscriptRange: att-ns-str r))))

(defmethod url-at-index ((self attributed-string) index)
  ;; Finds URL starting at specified index and returns an NSURL as first value,
  ;; location of URL string as second value, length of string as third.
  ;; Returns three values: 1) NSUrl if it is found or nil otherwise
  ;;                       2) Start of URL string if found or index otherwise
  ;;                       3) Length of URL string if found or length of remainder of string otherwise
  (let* ((ls (lisp-str self))
         (colon-pos (search "://" (subseq ls index)))
         (prev-space-pos (and colon-pos (position #\space (subseq ls 0 colon-pos) :from-end t))))    
    (if prev-space-pos
      (with-slots (att-ns-str) self
        (ns:with-ns-range (r 0 0)
          (values (obj-if-not-null (#/URLAtIndex:effectiveRange: att-ns-str (+ index 1 prev-space-pos) r))
                  (ns:ns-range-location r)
                  (ns:ns-range-length r))))
      (values nil index (- (length ls) index)))))

;;; methods for using attributed-string as an output stream

(defmethod close ((self attributed-string) &key abort)
  (declare (ignore abort)))

(defmethod stream-finish-output ((self attributed-string))
  (when (as-view self)
    (#/setNeedsDisplay: (as-view self) t)))

(defmethod stream-force-output ((self attributed-string))
  (when (as-view self)
    (#/setNeedsDisplay: (as-view self) t)))

(defmethod stream-line-column ((self attributed-string))
  (let ((nl-pos (position #\newline (lisp-str self) :from-end t)))
    (if nl-pos
      (- (attributed-string-length self) nl-pos 1)
      (attributed-string-length self))))

(defmethod stream-write-char ((self attributed-string) char)
  (append-string self (string char) :attrs (format-attributes self))
  (stream-finish-output self))

(defmethod stream-write-string ((self attributed-string) str
                                &optional
                                (start 0)
                                (end (length str)))
  (append-string self (subseq (string str) start end) :attrs (format-attributes self))
  (stream-finish-output self))

#|
Tests for attributed-string object:

(require :objc-initialize)
(in-package :iu)

(setf as (make-instance 'attributed-string
           :str "This is my string with an embedded link http://clozure.com which we'll let it look for."
           :attr (list (cons #$NSFontAttributeName (#/fontWithName:size: ns:ns-font #@"Helvetica-Bold" 12.0))
                       (cons #$NSForegroundColorAttributeName (#/redColor ns:ns-color))
                       (cons #$NSUnderlineStyleAttributeName #$NSUnderlineStyleSingle))))

(defvar *win*)
(defvar *label*)
(defvar *wc*)

(defun show-as (att-str)
  (declare (special *win* *wc* *label*))
  ;; display attributed string in new window
  (on-main-thread
   (when (and (boundp *win*) *win* (boundp *wc*) *wc*)
     (#/close *wc*)
     (#/release *label*)
     (#/release *win*)
     (#/release *wc*))
   (setf *label* (make-instance 'ns:ns-text-view
                   :editable t
                   :rich-text t
                   :frame '(0 0 500 300)
                   :string att-str))
   (setf *win* (make-instance 'ns:ns-window
                 :title "Attributed String Test"
                 :content-view *label*))
   (setf *wc* (make-instance 'ns:ns-window-controller
                :window *win*))
   (#/showWindow: *wc* (%null-ptr))))

(add-attribute as #$NSBackgroundColorAttributeName (#/greenColor ns:ns-color) :start 9 :length 9)

(show-as as)

(add-attributes as 
                (list (cons #$NSBackgroundColorAttributeName (#/grayColor ns:ns-color))
                      (cons #$NSFontAttributeName (#/fontWithName:size: ns:ns-font #@"Courier" 24.0)))
                :start 0
                :length 10)

(show-as as)

(append-string as "This is an appended string")

(show-as as)

(apply-font-traits as (logior #$NSItalicFontMask #$NSBoldFontMask) :start (- (length (lisp-str as)) 5))
;; physically changes the font, not just the attribute of the string

(show-as as)

(attribute-at-index as #$NSBackgroundColorAttributeName 5)  ;; should return grayColor

(attributed-string-equal as as)

(eql (attributed-string-length as) (length (lisp-str as)))

(setf ss (attributed-substring as :start 5))

(show-as ss)

(attributed-string-equal as ss)

(attributes-at-index as 8)

(setf rs (make-instance 'attributed-string
           :str "What "
           :attr (list (cons #$NSFontAttributeName (#/fontWithName:size: ns:ns-font #@"Arial-Black" 14.0))
                       (cons #$NSForegroundColorAttributeName (#/blueColor ns:ns-color)))))

(insert-attributed-string-at-index ss rs 0)

(show-as ss)

(remove-attribute as #$NSBoldFontMask :start (- (attributed-string-length as) 7))
;; note that removing a bold attribute does not change the underlying font characteristics which are bold.

(show-as as)

(replace-chars-in-range as "a plain replacement string" :start 8 :length 9)

(show-as as)

(replace-chars-in-range as rs :start 10 :length 6)

(show-as as)

(show-as ss)

(set-attributed-string ss rs)

(show-as ss)

(set-attributes as
                (list (cons #$NSBackgroundColorAttributeName (#/lightGrayColor ns:ns-color))
                      (cons #$NSFontAttributeName (#/fontWithName:size: ns:ns-font #@"Courier" 16.0)))
                :start 20
                :length 10)

(show-as as)

(subscript-range as :start 20 :length 10)

(show-as as)

(subscript-range as :start 20 :length 10)

(show-as as)

(superscript-range as :start 20 :length 10)

(show-as as)

(superscript-range as :start 20 :length 10)

(show-as as)

(superscript-range as :start 20 :length 10)

(show-as as)

(unscript-range as :start 20 :length 10)

(show-as as)

(url-at-index as 0)

(format as "~%~5TAnother line")

(show-as as)

(setf (iu::format-attributes as) (list (cons #$NSBackgroundColorAttributeName (#/lightGrayColor ns:ns-color))
                                          (cons #$NSFontAttributeName (#/fontWithName:size: ns:ns-font #@"Courier" 16.0))))

(format as "~%~5TAnother line")

(show-as as)

(setf lf (make-string 1 :initial-element #\linefeed))

(append-string as (concatenate 'string lf lf "This is a new line" lf "and another new line"))

(show-as as)
|#

#|

I've collected a bunch of parameter values here to make it a bit easier for Lisp developers. They are
current for OSX 10.6 as of March 2011 through OSX 10.11 as of March 2016.

The following constant names should be used to provide various parameters.
Use with #$ prefix; e.g. #$NSFontAttributeName. Even when equivalent values are shown, you should use
the constant name rather than the numeric equivalent in case the latter should change at some future time.

;;;;;;;;
Attribute type names
The second line defines the type of each value that must be provided.

NSFontAttributeName
  NSFont
    Default Helvetica 12-point

NSParagraphStyleAttributeName
  NSParagraphStyle
    Default as returned by the NSParagraphStyle method defaultParagraphStyle

NSForegroundColorAttributeName
  NSColor
    Default blackColor

NSUnderlineStyleAttributeName
  NSNumber containing integer
    Default 0, no underline.  See "Underlining Patterns", "Underlining Styles",
    and "Underline Masks" for mask values.

NSSuperscriptAttributeName
  NSNumber containing integer
    Default 0

NSBackgroundColorAttributeName
  NSColor
    Default nil, no background

NSAttachmentAttributeName
  NSTextAttachment
    Default nil, no attachment

NSLigatureAttributeName
  NSNumber containing integer
    Default 1, standard ligatures; 0, no ligatures; 2, all ligatures

NSBaselineOffsetAttributeName
  NSNumber containing floating point value, as points offset from baseline
    Default 0.0

NSKernAttributeName
  NSNumber containing floating point value, as points by which to modify default kerning
    Default nil, use default kerning specified in font file; 0.0, kerning off; non-zero, 
    points by which to modify default kerning

NSLinkAttributeName
  NSURL (preferred) or NSString
    Default nil, no link

NSStrokeWidthAttributeName
  NSNumber containing floating point value, as percent of font point size
    Default 0, no stroke; positive, stroke alone; negative, stroke and fill 
    (a typical value for outlined text would be 3.0)

NSStrokeColorAttributeName
  NSColor
    Default nil, same as foreground color

NSUnderlineColorAttributeName
  NSColor
    Default nil, same as foreground color

NSStrikethroughStyleAttributeName
  NSNumber containing integer
    Default 0, no strikethrough. See "Underlining Patterns", "Underlining Styles",
    and "Underline Masks" for mask values.

NSStrikethroughColorAttributeName
  NSColor
    Default nil, same as foreground color

NSShadowAttributeName
  NSShadow
    Default nil, no shadow

NSObliquenessAttributeName
  NSNumber containing floating point value, as skew to be applied to glyphs
    Default 0.0, no skew

NSExpansionAttributeName
  NSNumber containing floating point value, as log of expansion factor to be applied to glyphs
    Default 0.0, no expansion

NSCursorAttributeName
  NSCursor
    Default as returned by the NSCursor method IBeamCursor

NSToolTipAttributeName
  NSString
    Default nil, no tooltip

NSMarkedClauseSegmentAttributeName
  NSNumber containing an integer, as an index in marked text indicating clause segments 

NSWritingDirectionAttributeName
  An NSArray of NSNumbers.
    This provides a means to override the default bidi algorithm, equivalent to the use 
    of bidi control characters LRE, RLE, LRO, or RLO paired with PDF, as a higher-level 
    attribute. This is the NSAttributedString equivalent of HTML's dir attribute and/or 
    BDO element. The array represents nested embeddings or overrides, in order from 
    outermost to innermost. The values of the NSNumbers should be 0, 1, 2, or 3, for 
    LRE, RLE, LRO, or RLO respectively; these should be regarded as 
    NSWritingDirectionLeftToRight or NSWritingDirectionRightToLeft plus 
    NSTextWritingDirectionEmbedding or NSTextWritingDirectionOverride.

;;;;;
Underlining Styles

These constants define underlining style values for NSUnderlineStyleAttributeName 
and NSStrikethroughStyleAttributeName.

NSUnderlineStyleNone   = 0x00,
NSUnderlineStyleSingle   = 0x01,
NSUnderlineStyleThick   = 0x02,
NSUnderlineStyleDouble   = 0x09

;;;;;;
Underlining Patterns

NSUnderlinePatternSolid   = 0x0000,
NSUnderlinePatternDot   = 0x0100,
NSUnderlinePatternDash   = 0x0200,
NSUnderlinePatternDashDot   = 0x0300,
NSUnderlinePatternDashDotDot  = 0x0400

;;;;;;;
Underline Masks
This constant defines the underlining style for NSUnderlineStyleAttributeName and NSStrikethroughStyleAttributeName.

NSUnderlineByWordMask
    Draw the underline only underneath words, not underneath whitespace.

;;;;;;;
Font Traits
NSItalicFontMask = 0x00000001,
NSBoldFontMask = 0x00000002,
NSUnboldFontMask = 0x00000004,
NSNonStandardCharacterSetFontMask = 0x00000008,
NSNarrowFontMask = 0x00000010,
NSExpandedFontMask = 0x00000020,
NSCondensedFontMask = 0x00000040,
NSSmallCapsFontMask = 0x00000080,
NSPosterFontMask = 0x00000100,
NSCompressedFontMask = 0x00000200,
NSFixedPitchFontMask = 0x00000400,
NSUnitalicFontMask = 0x01000000

|#

(provide :attributed-strings)