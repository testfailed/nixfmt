{- © 2019 Serokell <hi@serokell.io>
 - © 2019 Lars Jellema <lars.jellema@gmail.com>
 -
 - SPDX-License-Identifier: MPL-2.0
 -}

{-# LANGUAGE FlexibleInstances, LambdaCase, OverloadedStrings #-}

module Nixfmt.Pretty where

import Prelude hiding (String)

import Data.Char (isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text, isPrefixOf, stripPrefix)
import qualified Data.Text as Text
  (empty, isInfixOf, last, null, replace, strip, takeWhile)

import Nixfmt.Predoc
  (Doc, Pretty, emptyline, group, hardline, hardspace, hcat, line, line', nest,
  newline, pretty, sepBy, softline, softline', text, textWidth)
import Nixfmt.Types
  (Ann(..), Binder(..), Expression(..), File(..), Leaf, ParamAttr(..),
  Parameter(..), Selector(..), SimpleSelector(..), StringPart(..), Term(..),
  Token(..), TrailingComment(..), Trivia, Trivium(..), tokenText)
import Nixfmt.Util (commonIndentation)

prettyCommentLine :: Text -> Doc
prettyCommentLine l
    | Text.null l = emptyline
    | otherwise   = text l <> hardline

toLineComment :: Text -> Trivium
toLineComment c = LineComment $ fromMaybe (" " <> c) $ stripPrefix "*" c

instance Pretty TrailingComment where
    pretty (TrailingComment c)
        = hardspace <> text "#" <> hardspace <> text c <> hardline

instance Pretty Trivium where
    pretty EmptyLine        = emptyline
    pretty (LineComment c)  = text "#" <> pretty c <> hardline
    pretty (BlockComment c)
        | all ("*" `isPrefixOf`) (tail c) = hcat (map toLineComment c)
        | otherwise
            = text "/*" <> hardspace <> (nest 3 $ hcat $ map prettyCommentLine c)
              <> text "*/" <> hardline

instance Pretty [Trivium] where
    pretty []     = mempty
    pretty trivia = hardline <> hcat trivia

instance Pretty a => Pretty (Ann a) where
    pretty (Ann x trailing leading)
        = pretty x <> pretty trailing <> pretty leading

instance Pretty SimpleSelector where
    pretty (IDSelector i)              = pretty i
    pretty (InterpolSelector interpol) = pretty interpol
    pretty (StringSelector (Ann s trailing leading))
        = prettySimpleString s <> pretty trailing <> pretty leading

instance Pretty Selector where
    pretty (Selector dot sel Nothing)
        = pretty dot <> pretty sel

    pretty (Selector dot sel (Just (kw, def)))
        = pretty dot <> pretty sel
          <> hardspace <> pretty kw <> hardspace <> pretty def

instance Pretty Binder where
    pretty (Inherit inherit Nothing ids semicolon)
        = group (pretty inherit <> softline
                 <> nest 2 (sepBy softline ids)) <> pretty semicolon

    pretty (Inherit inherit source ids semicolon)
        = group (pretty inherit <> hardspace
                 <> pretty source <> line
                 <> nest 2 (sepBy softline ids)) <> pretty semicolon

    pretty (Assignment selectors assign expr semicolon)
        = group (hcat selectors <> hardspace
                 <> nest 2 (pretty assign <> softline <> pretty expr))
          <> pretty semicolon

-- | Pretty print a term without wrapping it in a group.
prettyTerm :: Term -> Doc
prettyTerm (Token t) = pretty t
prettyTerm (String s) = pretty s
prettyTerm (Selection term selectors) = pretty term <> hcat selectors

prettyTerm (List (Ann paropen Nothing []) [] parclose)
    = pretty paropen <> hardspace <> pretty parclose

prettyTerm (List (Ann paropen Nothing []) [item] parclose)
    | isAbsorbable item
        = pretty paropen <> pretty item <> pretty parclose

prettyTerm (List (Ann paropen trailing leading) items parclose)
    = nest 0 $ pretty paropen <> pretty trailing <> line
        <> nest 2 (pretty leading <> sepBy line (map group items)) <> line
        <> pretty parclose

prettyTerm (Set Nothing (Ann paropen Nothing []) [] parclose)
    = pretty paropen <> hardspace <> pretty parclose

prettyTerm (Set krec (Ann paropen trailing leading) binders parclose)
    = nest 0 $ pretty (fmap ((<>hardspace) . pretty) krec)
        <> pretty paropen <> pretty trailing <> line
        <> nest 2 (pretty leading <> sepBy hardline binders) <> line
        <> pretty parclose

prettyTerm (Parenthesized paropen expr parclose)
    = pretty paropen <> nest 2 (group expr) <> pretty parclose

instance Pretty Term where
    pretty l@(List _ _ _) = group $ prettyTerm l
    pretty x              = prettyTerm x

toLeading :: Maybe TrailingComment -> Trivia
toLeading Nothing = []
toLeading (Just (TrailingComment c)) = [LineComment (" " <> c)]

prettyComma :: Maybe Leaf -> Doc
prettyComma Nothing = mempty
prettyComma (Just comma) = softline' <> pretty comma <> hardspace

instance Pretty ParamAttr where
    pretty (ParamAttr name Nothing comma)
        = pretty name <> prettyComma comma

    pretty (ParamAttr name (Just (qmark, def)) comma)
        = group (pretty name <> hardspace <> pretty qmark
            <> absorb softline mempty (Just 2) def)
            <> prettyComma comma

    pretty (ParamEllipsis ellipsis)
        = pretty ellipsis

instance Pretty Parameter where
    pretty (IDParameter i) = pretty i
    pretty (SetParameter bopen attrs bclose)
        = group $ pretty bopen <> hardspace
                  <> hcat attrs <> softline
                  <> pretty bclose

    pretty (ContextParameter param1 at param2)
        = pretty param1 <> pretty at <> pretty param2

isAbsorbable :: Term -> Bool
isAbsorbable (String (Ann parts@(_:_:_) _ _))
    = not $ isSimpleString parts
isAbsorbable (Set _ _ (_:_) _)                             = True
isAbsorbable (List (Ann _ Nothing []) [item] _)            = isAbsorbable item
isAbsorbable (Parenthesized (Ann _ Nothing []) (Term t) _) = isAbsorbable t
isAbsorbable (List _ (_:_:_) _)                            = True
isAbsorbable _                                             = False

absorb :: Doc -> Doc -> Maybe Int -> Expression -> Doc
absorb left right _ (Term t)
    | isAbsorbable t = toHardspace left <> prettyTerm t <> toHardspace right
    where toHardspace x | x == mempty    = mempty
                        | x == softline' = mempty
                        | x == line'     = mempty
                        | otherwise      = hardspace

absorb left right Nothing x = left <> pretty x <> right
absorb left right (Just level) x
    = left <> nest level (pretty x) <> right

absorbSet :: Expression -> Doc
absorbSet = absorb line mempty Nothing

absorbThen :: Expression -> Doc
absorbThen (Term t) | isAbsorbable t = hardspace <> prettyTerm t <> hardspace
absorbThen x                         = line <> nest 2 (group x) <> line

absorbElse :: Expression -> Doc
absorbElse (If if_ cond then_ expr0 else_ expr1)
    = hardspace <> pretty if_ <> hardspace <> group cond <> hardspace
      <> pretty then_ <> absorbThen expr0
      <> pretty else_ <> absorbElse expr1

absorbElse (Term t) | isAbsorbable t = hardspace <> prettyTerm t
absorbElse x                         = line <> nest 2 (group x)

absorbApp :: Expression -> Doc
absorbApp (Application f x) = softline <> pretty f <> absorbApp x
absorbApp (Term t) | isAbsorbable t = hardspace <> group (prettyTerm t)
absorbApp x = softline <> pretty x

instance Pretty Expression where
    pretty (Term t) = pretty t

    pretty (With with expr0 semicolon expr1)
        = pretty with <> hardspace
          <> nest 2 (group expr0) <> pretty semicolon
          <> absorbSet expr1

    pretty (Let (Ann let_ letTrailing letLeading) binders
                (Ann in_ inTrailing inLeading) expr)
        = group $ group (pretty let_ <> pretty letTrailing <> line
                         <> nest 2 (pretty letLeading
                                    <> sepBy hardline binders
                                    <> pretty (toLeading inTrailing)
                                    <> pretty inLeading)) <> line
          <> pretty in_ <> hardspace <> group expr

    pretty (Assert assert cond semicolon expr)
        = pretty assert <> hardspace
          <> nest 2 (group cond) <> pretty semicolon <> line
          <> absorbSet expr

    pretty (If if_ cond then_ expr0 else_ expr1)
        = group $ pretty if_ <> nest 0
            (hardspace <> group cond <> hardspace
            <> pretty then_ <> absorbThen expr0
            <> pretty else_ <> absorbElse expr1)

    pretty (Abstraction (IDParameter param) colon body)
        = pretty param <> pretty colon <> absorbAbs body
        where absorbAbs (Abstraction (IDParameter param0) colon0 body0) =
                  hardspace <> pretty param0 <> pretty colon0 <> absorbAbs body0
              absorbAbs x = absorbSet x

    pretty (Abstraction param colon body)
        = pretty param <> pretty colon <> absorbSet body

    pretty (Application f x) = group $ pretty f <> absorbApp x

    pretty (Operation a op b)
        = pretty a <> softline
          <> pretty op <> hardspace <> pretty b

    pretty (MemberCheck expr qmark sel)
        = pretty expr <> softline
          <> pretty qmark <> hardspace <> hcat sel

    pretty (Negation minus expr)
        = pretty minus <> pretty expr

    pretty (Inversion bang expr)
        = pretty bang <> pretty expr

instance Pretty File where
    pretty (File (Ann _ Nothing leading) expr)
        = group $ hcat leading <> pretty expr <> hardline

    pretty (File (Ann _ (Just (TrailingComment trailing)) leading) expr)
        = group $ text "# " <> pretty trailing <> hardline
                  <> hcat leading <> pretty expr <> hardline

instance Pretty Token where
    pretty = text . tokenText

instance Pretty [Token] where
    pretty = hcat

-- STRINGS

isSimpleSelector :: Selector -> Bool
isSimpleSelector (Selector _ (IDSelector _) Nothing) = True
isSimpleSelector _                                   = False

isSimple :: Expression -> Bool
isSimple (Term (Token (Ann (Identifier _) Nothing []))) = True
isSimple (Term (Selection t selectors))
    = isSimple (Term t) && all isSimpleSelector selectors
isSimple _ = False

hasQuotes :: [StringPart] -> Bool
hasQuotes []                = False
hasQuotes (TextPart x : xs) = Text.isInfixOf "\"" x || hasQuotes xs
hasQuotes (_ : xs)          = hasQuotes xs

hasDualQuotes :: [StringPart] -> Bool
hasDualQuotes []                = False
hasDualQuotes (TextPart x : xs) = Text.isInfixOf "''" x || hasDualQuotes xs
hasDualQuotes (_ : xs)          = hasDualQuotes xs

endsInSingleQuote :: [StringPart] -> Bool
endsInSingleQuote []           = False
endsInSingleQuote xs =
    case last xs of
         (TextPart x) -> x /= Text.empty && Text.last x == '\''
         _            -> False

isIndented :: [[StringPart]] -> Bool
isIndented parts =
    case commonIndentation inits of
         Just "" -> False
         _       -> True
    where textInit (TextPart t : xs) = t <> textInit xs
          textInit _                 = ""
          nonEmpty (TextPart "" : xs) = nonEmpty xs
          nonEmpty []                 = False
          nonEmpty _                  = True
          inits = map textInit $ filter nonEmpty parts

isEmptyLine :: [StringPart] -> Bool
isEmptyLine []           = True
isEmptyLine [TextPart t] = Text.strip t == Text.empty
isEmptyLine _            = False

isSimpleString :: [[StringPart]] -> Bool
isSimpleString [parts]
    | hasDualQuotes parts     = True
    | endsInSingleQuote parts = True
    | isIndented [parts]      = True
    | hasQuotes parts         = False
    | otherwise               = True

isSimpleString parts
    | all isEmptyLine parts = True
    | isIndented parts      = True
    | otherwise             = False

instance Pretty StringPart where
    pretty (TextPart t) = text t
    pretty (Interpolation paropen (Term t) parclose)
        | isAbsorbable t
            = group $ pretty paropen <> prettyTerm t <> pretty parclose

    pretty (Interpolation paropen expr parclose)
        | isSimple expr
            = pretty paropen <> pretty expr <> pretty parclose
        | otherwise
            = group $ pretty paropen <> line'
                <> nest 2 (pretty expr) <> line'
                <> pretty parclose

instance Pretty [StringPart] where
    pretty [Interpolation paropen expr parclose]
        = group $ pretty paropen <> pretty expr <> pretty parclose

    pretty (TextPart t : parts)
        = text t <> nest indentation (hcat parts)
        where indentation = textWidth $ Text.takeWhile isSpace t

    pretty parts = hcat parts

instance Pretty [[StringPart]] where
    pretty parts
        | isSimpleString parts = prettySimpleString parts
        | otherwise            = prettyIndentedString parts

prettySimpleString :: [[StringPart]] -> Doc
prettySimpleString parts = group $
    text "\""
    <> (sepBy (text "\\n") (map (pretty . map escape) parts))
    <> text "\""
    where escape (TextPart t) = TextPart
              $ Text.replace "$\\${" "$${"
              $ Text.replace "${" "\\${"
              $ Text.replace "\"" "\\\""
              $ Text.replace "\r" "\\r"
              $ Text.replace "\\" "\\\\" t
          escape x            = x

prettyIndentedString :: [[StringPart]] -> Doc
prettyIndentedString parts = group $ nest 0 $
    text "''" <> line'
    <> nest 2 (sepBy newline (map (pretty . map escape) parts))
    <> text "''"
    where escape (TextPart t) = TextPart
              $ Text.replace "$''${" "$${"
              $ Text.replace "${" "''${"
              $ Text.replace "''" "'''" t
          escape x            = x
