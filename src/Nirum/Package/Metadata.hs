{-# LANGUAGE GADTs, QuasiQuotes, RankNTypes, ScopedTypeVariables,
             StandaloneDeriving, TypeFamilies #-}
module Nirum.Package.Metadata ( Author (Author, email, name, uri)
                              , Metadata (Metadata, authors, target, version)
                              , MetadataError ( FieldError
                                              , FieldTypeError
                                              , FieldValueError
                                              , FormatError
                                              )
                              , MetadataField
                              , MetadataFieldType
                              , Node ( VArray
                                     , VBoolean
                                     , VDatetime
                                     , VFloat
                                     , VInteger
                                     , VString
                                     , VTable
                                     , VTArray
                                     )
                              , Package (Package, metadata, modules)
                              , Table
                              , Target ( CompileError
                                       , CompileResult
                                       , compilePackage
                                       , parseTarget
                                       , showCompileError
                                       , targetName
                                       , toByteString
                                       )
                              , TargetName
                              , VTArray
                              , metadataFilename
                              , metadataPath
                              , parseMetadata
                              , packageTarget
                              , prependMetadataErrorField
                              , readFromPackage
                              , readMetadata
                              , stringField
                              , tableField
                              ) where

import Data.Proxy (Proxy (Proxy))
import Data.Typeable (Typeable)
import GHC.Exts (IsList (fromList, toList))

import Data.ByteString (ByteString)
import qualified Data.HashMap.Strict as HM
import Data.Map.Strict (Map)
import qualified Data.SemVer as SV
import Data.Text (Text, append, snoc, unpack)
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.IO as TIO
import System.FilePath ((</>))
import Text.Email.Parser (EmailAddress)
import qualified Text.Email.Validate as EV
import Text.InterpolatedString.Perl6 (qq)
import Text.Parsec.Error (ParseError)
import Text.Toml (parseTomlDoc)
import Text.Toml.Types (Node ( VArray
                             , VBoolean
                             , VDatetime
                             , VFloat
                             , VInteger
                             , VString
                             , VTable
                             , VTArray
                             )
                       , Table
                       , VTArray
                       )
import Text.URI (URI, parseURI)

import Nirum.Package.ModuleSet (ModuleSet)

-- | The filename of Nirum package metadata.
metadataFilename :: FilePath
metadataFilename = "package.toml"

-- | Represents a package which consists of modules.
data Package t =
    Package { metadata :: (Eq t, Ord t, Show t, Target t) => Metadata t
            , modules :: ModuleSet
            }

deriving instance (Eq t, Target t) => Eq (Package t)
deriving instance (Ord t, Target t) => Ord (Package t)
deriving instance (Show t, Target t) => Show (Package t)

packageTarget :: Target t => Package t -> t
packageTarget Package { metadata = Metadata _ _ t } = t

data Metadata t =
    Metadata { version :: SV.Version
             , authors :: [Author]
             , target :: (Eq t, Ord t, Show t, Target t) => t
             }
-- TODO: uri, dependencies

deriving instance (Eq t, Target t) => Eq (Metadata t)
deriving instance (Ord t, Target t) => Ord (Metadata t)
deriving instance (Show t, Target t) => Show (Metadata t)

data Author = Author { name :: Text
                     , email :: Maybe EmailAddress
                     , uri :: Maybe URI
                     } deriving (Eq, Ord, Show)

type TargetName = Text

class (Eq t, Ord t, Show t, Typeable t) => Target t where
    type family CompileResult t :: *
    type family CompileError t :: *

    -- | The name of the given target e.g. @"python"@.
    targetName :: Proxy t -> TargetName

    -- | Parse the target metadata.
    parseTarget :: Table -> Either MetadataError t

    -- | Compile the package to a source tree of the target.
    compilePackage :: Package t
                   -> Map FilePath (Either (CompileError t) (CompileResult t))

    -- | Show a human-readable message from the given 'CompileError'.
    showCompileError :: t -> CompileError t -> Text

    -- | Encode the given 'CompileResult' to a 'ByteString'
    toByteString :: t -> CompileResult t -> ByteString

-- | Name of package.toml field.
type MetadataField = Text

-- | Typename of package.toml field e.g. @"string"@, @"array of 3 values"@.
type MetadataFieldType = Text

-- | Error related to parsing package.toml.
data MetadataError
    -- | A required field is missing.
    = FieldError MetadataField
    -- | A field has a value of incorrect type e.g. array for @version@ field.
    | FieldTypeError MetadataField MetadataFieldType MetadataFieldType
    -- | A field has a value of invalid format
    -- e.g. @"1/2/3"@ for @version@ field.
    | FieldValueError MetadataField String
    -- | The given package.toml file is not a valid TOML.
    | FormatError ParseError
    deriving (Eq, Show)

-- | Prepend the given prefix to a 'MetadataError' value's field information.
-- Note that a period is automatically inserted right after the given prefix.
-- It's useful for handling of accessing nested tables.
prependMetadataErrorField :: MetadataField -> MetadataError -> MetadataError
prependMetadataErrorField prefix e =
    case e of
        FieldError f -> FieldError $ prepend f
        FieldTypeError f e' a -> FieldTypeError (prepend f) e' a
        FieldValueError f m -> FieldValueError (prepend f) m
        e'@(FormatError _) -> e'
  where
    prepend :: MetadataField -> MetadataField
    prepend = (prefix `snoc` '.' `append`)

parseMetadata :: forall t . Target t
              => FilePath -> Text -> Either MetadataError (Metadata t)
parseMetadata metadataPath' tomlText = do
    table <- case parseTomlDoc metadataPath' tomlText of
        Left e -> Left $ FormatError e
        Right t -> Right t
    version' <- versionField "version" table
    authors' <- authorsField "authors" table
    targets <- tableField "targets" table
    targetTable <- case tableField targetName' targets of
        Left e -> Left $ prependMetadataErrorField "targets" e
        otherwise' -> otherwise'
    target' <- case parseTarget targetTable of
        Left e -> Left $ prependMetadataErrorField "targets"
                       $ prependMetadataErrorField targetName' e
        otherwise' -> otherwise'
    return Metadata { version = version'
                    , authors = authors'
                    , target = target'
                    }
  where
    targetName' :: Text
    targetName' = targetName (Proxy :: Proxy t)

readMetadata :: Target t => FilePath -> IO (Either MetadataError (Metadata t))
readMetadata metadataPath' = do
    tomlText <- TIO.readFile metadataPath'
    return $ parseMetadata metadataPath' tomlText

metadataPath :: FilePath -> FilePath
metadataPath = (</> metadataFilename)

readFromPackage :: Target t
                => FilePath -> IO (Either MetadataError (Metadata t))
readFromPackage = readMetadata . metadataPath

printNode :: Node -> MetadataFieldType
printNode (VTable t) = if length t == 1
                       then "table of an item"
                       else [qq|table of {length t} items|]
printNode (VTArray a) = [qq|array of {length a} tables|]
printNode (VString s) = [qq|string ($s)|]
printNode (VInteger i) = [qq|integer ($i)|]
printNode (VFloat f) = [qq|float ($f)|]
printNode (VBoolean True) = "boolean (true)"
printNode (VBoolean False) = "boolean (false)"
printNode (VDatetime d) = [qq|datetime ($d)|]
printNode (VArray a) = [qq|array of {length a} values|]

field :: MetadataField -> Table -> Either MetadataError Node
field field' table =
    case HM.lookup field' table of
        Just node -> return node
        Nothing -> Left $ FieldError field'

typedField :: MetadataFieldType
           -> (Node -> Maybe v)
           -> MetadataField
           -> Table
           -> Either MetadataError v
typedField typename match field' table = do
    node <- field field' table
    case match node of
        Just value -> return value
        Nothing -> Left $ FieldTypeError field' typename $ printNode node

optional :: Either MetadataError a -> Either MetadataError (Maybe a)
optional (Right value) = Right $ Just value
optional (Left (FieldError _)) = Right Nothing
optional (Left error') = Left error'

tableField :: MetadataField -> Table -> Either MetadataError Table
tableField = typedField "table" $ \ n -> case n of
                                              VTable t -> Just t
                                              _ -> Nothing

stringField :: MetadataField -> Table -> Either MetadataError Text
stringField = typedField "string" $ \ n -> case n of
                                                VString s -> Just s
                                                _ -> Nothing

tableArrayField :: MetadataField -> Table -> Either MetadataError VTArray
tableArrayField f t =
    case arrayF f t of
        Right vector -> Right vector
        Left (FieldError _) -> Right $ fromList []
        Left error' -> Left error'
  where
    arrayF :: MetadataField -> Table -> Either MetadataError VTArray
    arrayF = typedField "array of tables" $ \ node ->
        case node of
            VTArray array -> Just array
            _ -> Nothing

uriField :: MetadataField -> Table -> Either MetadataError URI
uriField field' table = do
    s <- stringField field' table
    case parseURI (unpack s) of
        Just uri' -> Right uri'
        Nothing -> Left $ FieldValueError field'
                                          [qq|expected a URI string, not $s|]

emailField :: MetadataField -> Table -> Either MetadataError EmailAddress
emailField field' table = do
    s <- stringField field' table
    case EV.validate (encodeUtf8 s) of
        Right emailAddress -> Right emailAddress
        Left e -> Left $
            FieldValueError field' [qq|expected an email address, not $s; $e|]

versionField :: MetadataField -> Table -> Either MetadataError SV.Version
versionField field' table = do
    s <- stringField field' table
    case SV.fromText s of
        Right v -> return v
        Left _ -> Left $ FieldValueError field' $
                    "expected a semver string (e.g. \"1.2.3\"), not " ++ show s

authorsField :: MetadataField -> Table -> Either MetadataError [Author]
authorsField field' table = do
    array <- tableArrayField field' table
    authors' <- mapM parseAuthor array
    return $ toList authors'
  where
    parseAuthor :: Table -> Either MetadataError Author
    parseAuthor t = do
        name' <- stringField "name" t
        email' <- optional $ emailField "email" t
        uri' <- optional $ uriField "uri" t
        return Author { name = name'
                      , email = email'
                      , uri = uri'
                      }
