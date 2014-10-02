perl-LC is a set of Perl modules written by Lionel Cons (CERN), providing methods for
securely manipulating/managing files, processes and a few other utilities.

Quattor has been relying strongly on perl-LC. But this is a no longer supported
component (there is a replacement also written by L. Cons, No-Worries, 
http://search.cpan.org/dist/No-Worries/).

Quattor components must not make any new use of perl-LC or No-Worries.
Instead they must use the relevant CAF modules (https://github.com/quattor/CAF)
that encapsulate the use of such modules and provide the ability to mock them 
for unit testing.

