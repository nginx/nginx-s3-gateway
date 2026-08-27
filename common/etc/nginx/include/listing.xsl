<?xml version="1.0"?>
<xsl:stylesheet version="1.1" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:str="http://exslt.org/strings" extension-element-prefixes="str">
    <xsl:output method="html" encoding="utf-8" indent="yes"/>
    <xsl:strip-space elements="*" />

    <xsl:param name="rootPath" />
    <xsl:param name="prefixPath" />

    <!-- The env value may carry percent-escapes, but njs decodes the full
         request path (prefix included) before building the S3 list prefix,
         so S3 echoes Prefix/Key values back decoded. Decode here too or an
         escaped prefix would never match them and silently not strip. -->
    <xsl:variable name="decodedPrefixPath"
                  select="str:decode-uri($prefixPath, 'UTF-8')"/>

    <!-- PREFIX_LEADING_DIRECTORY_PATH as S3 sees it: no leading slash (S3 keys
         carry none) and exactly one trailing slash, so it can be compared
         against raw Prefix/Key values. Empty or "/" disables stripping. -->
    <xsl:variable name="prefixPathNoLeadingSlash">
        <xsl:choose>
            <xsl:when test="starts-with($decodedPrefixPath, '/')">
                <xsl:value-of select="substring($decodedPrefixPath, 2)"/>
            </xsl:when>
            <xsl:otherwise>
                <xsl:value-of select="$decodedPrefixPath"/>
            </xsl:otherwise>
        </xsl:choose>
    </xsl:variable>
    <xsl:variable name="normalizedPrefixPath">
        <xsl:choose>
            <xsl:when test="string-length($prefixPathNoLeadingSlash) = 0"/>
            <xsl:when test="substring($prefixPathNoLeadingSlash, string-length($prefixPathNoLeadingSlash)) = '/'">
                <xsl:value-of select="$prefixPathNoLeadingSlash"/>
            </xsl:when>
            <xsl:otherwise>
                <xsl:value-of select="concat($prefixPathNoLeadingSlash, '/')"/>
            </xsl:otherwise>
        </xsl:choose>
    </xsl:variable>

    <xsl:template match="/">
        <xsl:choose>
            <xsl:when test="//*[local-name()='Contents'] or //*[local-name()='CommonPrefixes']">
                <xsl:apply-templates select="*[local-name()='ListBucketResult']" />
            </xsl:when>
            <xsl:otherwise>
                <xsl:call-template name="no_contents"/>
            </xsl:otherwise>
        </xsl:choose>

    </xsl:template>

    <!-- When FOUR_O_FOUR_ON_EMPTY_BUCKET is disabled (the default setting),
         the following template will be executed when the bucket is empty. -->
    <xsl:template name="no_contents">
        <html>
            <head><title>No Files Available for Listing</title></head>
            <body>
                <h1>No Files Available for Listing</h1>
            </body>
        </html>
    </xsl:template>

    <xsl:template match="*[local-name()='ListBucketResult']">
        <xsl:text disable-output-escaping='yes'>&lt;!DOCTYPE html&gt;</xsl:text>
        <xsl:variable name="globalPrefix"
                      select="*[local-name()='Prefix']/text()"/>
        <!-- The directory name as the client sees it: the gateway re-prepends
             PREFIX_LEADING_DIRECTORY_PATH to every incoming URI, so displayed
             paths and links must not contain it. -->
        <xsl:variable name="displayPrefix">
            <xsl:call-template name="strip-prefix">
                <xsl:with-param name="uri" select="$globalPrefix"/>
            </xsl:call-template>
        </xsl:variable>
        <html>
            <head>
                <title><xsl:value-of select="$displayPrefix"/>
                </title>
            </head>
            <body>
                <h1>Index of /<xsl:value-of select="concat($rootPath, $displayPrefix)"/></h1>
                <hr/>
                <table id="list">
                    <thead>
                        <tr>
                            <th style="text-align: left; width:55%">Filename
                            </th>
                            <th style="text-align: left; width:20%">File Size
                            </th>
                            <th style="text-align: left; width:25%">Date</th>
                        </tr>
                    </thead>
                    <tbody>
                        <xsl:if test="string-length($displayPrefix) > 0">
                            <tr>
                                <td>
                                    <a href="../">..</a>
                                </td>
                            </tr>
                        </xsl:if>
                        <xsl:apply-templates
                                select="*[local-name()='CommonPrefixes']">
                            <xsl:with-param name="globalPrefix"
                                            select="$globalPrefix"/>
                        </xsl:apply-templates>
                        <xsl:apply-templates
                                select="*[local-name()='Contents']">
                            <xsl:with-param name="globalPrefix"
                                            select="$globalPrefix"/>
                        </xsl:apply-templates>
                    </tbody>
                </table>
                <!-- The client-facing continuation marker: NextMarker with
                     the response Prefix stripped, computed once so the
                     guard below and the href always agree on one value. -->
                <xsl:variable name="nextMarker"
                              select="substring-after(*[local-name()='NextMarker']/text(), $globalPrefix)"/>
                <!-- S3 truncates ListObjects responses at max-keys (at most
                     1000 keys); with a delimiter the V1 API returns
                     NextMarker on every truncated response. The emitted
                     marker is relative to the listed directory: njs
                     re-prepends the S3 prefix (including any
                     PREFIX_LEADING_DIRECTORY_PATH) when building the next
                     list request, so the internal prefix never leaks into
                     the link. The href is a query-only relative reference,
                     resolved against the current directory URL, so no
                     rootPath handling applies. The guard anchors the strip:
                     substring-after cuts at the FIRST prefix occurrence
                     anywhere in the string, so only a NextMarker that
                     literally STARTS WITH the prefix may render a link -
                     when a backend truncates without NextMarker, with an
                     opaque token that is not prefix-anchored (stripping such
                     a token mid-string would fabricate a continuation
                     point), or with a marker equal to the prefix, no link
                     renders. njs treats an empty ?marker= as absent, so an
                     empty-valued link would reload the same page forever.
                     The no-link fallback is the same output as before
                     pagination existed. -->
                <xsl:if test="*[local-name()='IsTruncated']/text() = 'true' and starts-with(*[local-name()='NextMarker']/text(), $globalPrefix) and string-length($nextMarker) &gt; 0">
                    <hr/>
                    <p><a><xsl:attribute name="href">?marker=<xsl:call-template name="encode-marker"><xsl:with-param name="value" select="$nextMarker"/></xsl:call-template></xsl:attribute>Next page</a></p>
                </xsl:if>
            </body>
        </html>
    </xsl:template>
    <xsl:template match="*[local-name()='CommonPrefixes']">
        <xsl:param name="globalPrefix"/>
        <xsl:apply-templates select=".//*[local-name()='Prefix']">
            <xsl:with-param name="globalPrefix" select="$globalPrefix"/>
        </xsl:apply-templates>
    </xsl:template>
    <xsl:template match="*[local-name()='Prefix']">
        <xsl:param name="globalPrefix"/>
        <xsl:if test="not(text()=$globalPrefix)">
            <xsl:variable name="dirName"
                          select="substring-after(text(), $globalPrefix)"/>
            <tr>
                <td>
                    <a><xsl:attribute name="href">/<xsl:call-template name="encode-uri"><xsl:with-param name="uri" select="text()"/></xsl:call-template>/</xsl:attribute>
                        <xsl:value-of select="$dirName"/>
                    </a>
                </td>
                <td/>
                <td/>
            </tr>
        </xsl:if>
    </xsl:template>

    <xsl:template match="*[local-name()='Contents']">
        <xsl:param name="globalPrefix"/>
        <xsl:variable name="key" select="*[local-name()='Key']/text()"/>

        <xsl:if test="not($key=$globalPrefix)">
            <xsl:variable name="fileName"
                          select="substring-after($key, $globalPrefix)"/>
            <xsl:variable name="date"
                          select="*[local-name()='LastModified']/text()"/>
            <xsl:variable name="size" select="*[local-name()='Size']/text()"/>
            <tr>
                <td>
                    <a>
                        <xsl:attribute name="href">/<xsl:call-template name="encode-uri"><xsl:with-param name="uri" select="$key"/></xsl:call-template></xsl:attribute>
                        <xsl:value-of select="$fileName"/>
                    </a>
                </td>
                <td>
                    <xsl:value-of select="$size"/>
                </td>
                <td>
                    <xsl:value-of select="$date"/>
                </td>
            </tr>
        </xsl:if>
    </xsl:template>
    <!-- Returns $uri with the internal PREFIX_LEADING_DIRECTORY_PATH removed:
         the gateway re-prepends that prefix to every incoming URI, so a link
         that still contains it would be prefixed a second time when followed.
         URIs that do not carry the prefix pass through unchanged. -->
    <xsl:template name="strip-prefix">
        <xsl:param name="uri"/>
        <xsl:choose>
            <xsl:when test="string-length($normalizedPrefixPath) > 0 and starts-with($uri, $normalizedPrefixPath)">
                <xsl:value-of select="substring-after($uri, $normalizedPrefixPath)"/>
            </xsl:when>
            <xsl:otherwise>
                <xsl:value-of select="$uri"/>
            </xsl:otherwise>
        </xsl:choose>
    </xsl:template>
    <!-- This template escapes the URI such that symbols or unicode characters are
         encoded so that they form a valid link that NGINX can parse -->
    <xsl:template name="encode-uri">
        <xsl:param name="uri"/>
        <xsl:variable name="strippedUri">
            <xsl:call-template name="strip-prefix">
                <xsl:with-param name="uri" select="$uri"/>
            </xsl:call-template>
        </xsl:variable>
        <xsl:variable name="prefixed_uri" select="concat($rootPath, $strippedUri)" />
        <xsl:for-each select="str:split($prefixed_uri, '/')">
            <xsl:call-template name="encode-marks"><xsl:with-param name="encoded" select="str:encode-uri(., 'true', 'UTF-8')"/></xsl:call-template><xsl:if test="position() != last()">/</xsl:if></xsl:for-each>
    </xsl:template>
    <!-- Percent-encodes a string for use as a URL query-parameter VALUE:
         unlike encode-uri, the '/' separator must be encoded too (the
         marker is a single value, not a path) and no rootPath or
         prefix-stripping applies. njs decodes and re-encodes the value on
         the next request, so any residual bare character still
         round-trips. -->
    <xsl:template name="encode-marker">
        <xsl:param name="value"/>
        <xsl:call-template name="encode-marks">
            <xsl:with-param name="encoded" select="str:encode-uri($value, 'true', 'UTF-8')"/>
        </xsl:call-template>
    </xsl:template>
    <!-- Normalizes the mark characters that str:encode-uri leaves bare
         even with escape-reserved (it encodes the URI delimiters,
         including '/', '&', '=', '+' and '%', but not the marks) to the
         percent-encoded forms njs _encodeURIComponent() produces. Shared
         by encode-uri (per path segment) and encode-marker (whole query
         value) so the client-facing encoding alphabet is defined once. -->
    <xsl:template name="encode-marks">
        <xsl:param name="encoded"/>
        <xsl:value-of select="
            str:replace(
                str:replace(
                    str:replace(
                        str:replace(
                            str:replace($encoded, '@', '%40'), '(', '%28'),
                        ')', '%29'),
                    '!', '%21'),
                '*', '%2A')"/>
    </xsl:template>
</xsl:stylesheet>
