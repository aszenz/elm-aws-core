module AWS.Signers.V4 exposing (..)

import AWS.Config exposing (Credentials)
import AWS.Signers.Canonical exposing (canonical, signedHeaders)
import AWS.Http exposing (UnsignedRequest, RequestParams)
import Date exposing (Date)
import Date.Format exposing (formatISO8601)
import Http
import Regex exposing (HowMany(All), regex)
import Native.HMAC


-- http://docs.aws.amazon.com/waf/latest/developerguide/authenticating-requests.html


sign :
    AWS.Config.Service
    -> AWS.Config.Credentials
    -> Date
    -> UnsignedRequest a
    -> Result String (Http.Request a)
sign config creds date req =
    Http.request
        { method = req.method
        , headers =
            headers config
                |> addAuthorization config creds date req
                |> addSessionToken creds
                |> List.map (\( key, val ) -> Http.header key val)
        , url = AWS.Http.url config.endpoint req.path req.params
        , body = AWS.Http.body req.params
        , expect = Http.expectJson req.decoder
        , timeout = Nothing
        , withCredentials = False
        }
        |> Ok


algorithm : String
algorithm =
    "AWS4-HMAC-SHA256"


headers : AWS.Config.Service -> List ( String, String )
headers config =
    [ ( "Host", AWS.Http.host config.endpoint )
    , ( "Content-Type", jsonContentType config )
    ]


formatDate : Date -> String
formatDate date =
    date
        |> formatISO8601
        |> Regex.replace All
            (regex "([-:]|\\.\\d{3})")
            (\_ -> "")


addSessionToken :
    AWS.Config.Credentials
    -> List ( String, String )
    -> List ( String, String )
addSessionToken creds headers =
    creds.sessionToken
        |> Maybe.map
            (\token ->
                ( "x-amz-security-token", token ) :: headers
            )
        |> Maybe.withDefault headers


addAuthorization :
    AWS.Config.Service
    -> AWS.Config.Credentials
    -> Date
    -> UnsignedRequest a
    -> List ( String, String )
    -> List ( String, String )
addAuthorization config creds date req headers =
    [ ( "X-Amz-Date", formatDate date )
    , ( "Authorization", authorization creds date config req headers )
    ]
        |> List.append headers


authorization :
    Credentials
    -> Date
    -> AWS.Config.Service
    -> UnsignedRequest a
    -> List ( String, String )
    -> String
authorization creds date config req headers =
    let
        canon =
            canonical req.method req.path headers req.params

        scope =
            credentialScope date creds config
    in
        [ "AWS4-HMAC-SHA256 Credential="
            ++ creds.accessKeyId
            ++ "/"
            ++ scope
        , "SignedHeaders="
            ++ signedHeaders headers
        , "Signature="
            ++ signature creds config date (stringToSign algorithm date scope canon)
        ]
            |> String.join ", "


credentialScope : Date -> AWS.Config.Credentials -> AWS.Config.Service -> String
credentialScope date creds config =
    [ date |> formatDate |> String.slice 0 8
    , (config.endpoint |> regionForAuth)
    , config.serviceName
    , "aws4_request"
    ]
        |> String.join "/"


signature : Credentials -> AWS.Config.Service -> Date -> String -> String
signature creds config date toSign =
    Native.HMAC.signatureKey
        creds.secretAccessKey
        (date |> formatDate |> String.slice 0 8)
        (config.endpoint |> regionForAuth)
        config.serviceName
        toSign


regionForAuth : AWS.Config.Endpoint -> String
regionForAuth endpoint =
    case endpoint of
        AWS.Config.RegionalEndpoint _ region ->
            region

        AWS.Config.GlobalEndpoint _ ->
            -- See http://docs.aws.amazon.com/general/latest/gr/sigv4_changes.html
            "us-east-1"


stringToSign : String -> Date -> String -> String -> String
stringToSign algorithm date scope canon =
    [ algorithm
    , date |> formatDate
    , scope
    , canon
    ]
        |> String.join "\n"


jsonContentType : AWS.Config.Service -> String
jsonContentType config =
    (case config.xAmzJsonVersion of
        Just version ->
            "application/x-amz-json-" ++ version

        Nothing ->
            "application/json"
    )
        ++ "; charset=utf-8"